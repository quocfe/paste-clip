import AppKit
import Darwin
import os

/// Imports newly saved macOS screenshots without modifying the system clipboard.
@MainActor
public final class ScreenshotWatcher {
    public var onCapture: ((CapturedClip) -> Void)?
    public var onError: ((String) -> Void)?
    public var paused = false {
        didSet {
            // A screenshot taken while paused must never be backfilled on resume.
            if oldValue != paused { activeSince = Date() }
        }
    }
    private var activeSince = Date()
    private var handled: [URL: Date] = [:]
    private var timer: Timer?
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private let directories: () -> [URL]
    private let pendingDirectories: () throws -> [URL]
    private var pendingUnavailable = false
    private var reportedDirectories = Set<URL>()
    private var inFlight = Set<URL>()

    public init(
        directories: @escaping () -> [URL] = ScreenshotWatcher.systemDirectories,
        pendingDirectories: @escaping () throws -> [URL] = { [] }
    ) {
        self.directories = directories
        self.pendingDirectories = pendingDirectories
    }
    /// While the floating thumbnail is on screen (about five seconds), macOS keeps a new
    /// screenshot in a private folder under the user's temporary directory and only then moves
    /// it to its destination. Reading it there makes the import immediate.
    nonisolated public static func systemPendingDirectories() throws -> [URL] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryItems", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("NSIRD_screencaptureui_") }
    }
    nonisolated static let diagnostics = Logger(subsystem: "com.quocfe.ClipStack", category: "screenshots")
    nonisolated public static func systemDirectories() -> [URL] {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Desktop", isDirectory: true)
        let preferences = UserDefaults(suiteName: "com.apple.screencapture")
        guard let location = preferences?.string(forKey: "location"), !location.isEmpty else { return [desktop] }
        let custom = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        return Array(Set([desktop, custom]))
    }
    public func start() {
        guard timer == nil else { return }
        activeSince = Date()
        handled.removeAll()
        pendingUnavailable = false
        // Spotlight covers Save As and custom destinations; folder polling avoids indexing latency.
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(
            format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", activeSince as NSDate)
        query.notificationBatchingInterval = 0.5
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.collectQueryResults() }
                })
        }
        query.start()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    public func stop() {
        timer?.invalidate()
        timer = nil
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
    public func poll() async {
        guard !paused else { return }
        await collect(pendingFiles(), metadataConfirmed: true, requireSettled: true)
        var candidates: [URL] = []
        for directory in directories() {
            do {
                candidates += try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
                    ],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                reportedDirectories.remove(directory)
            } catch {
                if reportedDirectories.insert(directory).inserted {
                    onError?(
                        "Could not watch screenshots in \(directory.path). Allow ClipStack access to this folder in System Settings → Privacy & Security → Files and Folders. \(error.localizedDescription)"
                    )
                }
            }
        }
        await collect(candidates, metadataConfirmed: false)
    }
    private func pendingFiles() -> [URL] {
        guard !pendingUnavailable else { return [] }
        do {
            // These folders come and go with each capture, so a missing one is not an error.
            return try pendingDirectories().flatMap {
                (try? FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            }
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            // Newer macOS versions protect this folder. Screenshots are then imported when
            // they reach their destination; stop asking until the watcher restarts.
            pendingUnavailable = true
            Self.diagnostics.notice("Pending screenshots are not readable; waiting for saved files instead.")
            return []
        } catch {
            return []
        }
    }
    private func collectQueryResults() {
        guard !paused else { return }
        query.disableUpdates()
        let urls = (query.results as? [NSMetadataItem] ?? []).compactMap {
            ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
        }
        query.enableUpdates()
        Task { await collect(urls, metadataConfirmed: true) }
    }
    private func collect(_ urls: [URL], metadataConfirmed: Bool, requireSettled: Bool = false) async {
        // A file still being written in place must not be imported half-finished.
        let settledBefore = Date().addingTimeInterval(-0.2)
        let candidates = urls.compactMap { url -> (URL, Date, Date)? in
            guard
                let values = try? url.resourceValues(forKeys: [
                    .creationDateKey, .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
                ]),
                values.isRegularFile == true, let created = values.creationDate, created >= activeSince,
                let modified = values.contentModificationDate, handled[url] != modified,
                !requireSettled || modified <= settledBefore,
                let size = values.fileSize, size > 0, size <= ClipboardParser.maxPayloadBytes,
                metadataConfirmed || Self.isScreenshot(url)
            else { return nil }
            return (url, created, modified)
        }.sorted { $0.1 < $1.1 }
        for (url, created, modified) in candidates {
            // Another pass may have picked this file up while an earlier one was decoding.
            guard handled[url] != modified, inFlight.insert(url).inserted else { continue }
            // Reading and re-encoding a large screenshot must not block the main actor.
            let clip = await Task.detached(priority: .utility) {
                Self.readScreenshot(url, capturedAt: created)
            }.value
            inFlight.remove(url)
            // A partial write is retried on the next poll, only a decoded image is marked handled.
            guard let clip, !paused, created >= activeSince else { continue }
            handled[url] = modified
            onCapture?(clip)
        }
    }
    nonisolated static func isScreenshot(_ url: URL) -> Bool {
        let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0, size < 4096 else { return false }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard count == size,
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return false }
        return (value as? NSNumber)?.boolValue == true || (value as? String) == "1"
    }
    nonisolated public static func readScreenshot(_ url: URL, capturedAt: Date) -> CapturedClip? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= ClipboardParser.maxPayloadBytes,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return ImageNormalizer.clip(
            from: data, sourceID: "com.apple.screencaptureui", sourceName: "Screenshot",
            capturedAt: capturedAt)
    }
}
