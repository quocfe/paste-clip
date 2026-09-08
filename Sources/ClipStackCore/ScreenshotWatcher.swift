import AppKit
import Darwin

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
    private var reportedDirectories = Set<URL>()

    public init(directories: @escaping () -> [URL] = ScreenshotWatcher.systemDirectories) {
        self.directories = directories
    }
    nonisolated public static func systemDirectories() -> [URL] {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let preferences = UserDefaults(suiteName: "com.apple.screencapture")
        guard let location = preferences?.string(forKey: "location"), !location.isEmpty else { return [desktop] }
        let custom = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        return Array(Set([desktop, custom]))
    }
    public func start() {
        guard timer == nil else { return }
        activeSince = Date()
        handled.removeAll()
        // Spotlight covers Save As and custom destinations; folder polling avoids indexing latency.
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", activeSince as NSDate)
        query.notificationBatchingInterval = 0.5
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collectQueryResults() }
            })
        }
        query.start()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    public func stop() {
        timer?.invalidate(); timer = nil
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
    public func poll() {
        guard !paused else { return }
        var candidates: [URL] = []
        for directory in directories() {
            do {
                candidates += try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                reportedDirectories.remove(directory)
            } catch {
                if reportedDirectories.insert(directory).inserted {
                    onError?("Could not watch screenshots in \(directory.path). Allow ClipStack access to this folder in System Settings → Privacy & Security → Files and Folders. \(error.localizedDescription)")
                }
            }
        }
        collect(candidates, metadataConfirmed: false)
    }
    private func collectQueryResults() {
        guard !paused else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let urls = (query.results as? [NSMetadataItem] ?? []).compactMap {
            ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
        }
        collect(urls, metadataConfirmed: true)
    }
    private func collect(_ urls: [URL], metadataConfirmed: Bool) {
        let candidates = urls.compactMap { url -> (URL, Date, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let created = values.creationDate, created >= activeSince,
                  let modified = values.contentModificationDate, handled[url] != modified,
                  let size = values.fileSize, size > 0, size <= ClipboardParser.maxPayloadBytes,
                  metadataConfirmed || Self.isScreenshot(url) else { return nil }
            return (url, created, modified)
        }.sorted { $0.1 < $1.1 }
        for (url, created, modified) in candidates {
            // A partial write is retried on the next poll, only a decoded image is marked handled.
            guard let clip = Self.readScreenshot(url, capturedAt: created) else { continue }
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
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? NSNumber)?.boolValue == true || (value as? String) == "1"
    }
    public static func readScreenshot(_ url: URL, capturedAt: Date) -> CapturedClip? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ClipboardParser.maxPayloadBytes,
              let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= 40_000_000,
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= ClipboardParser.maxPayloadBytes else { return nil }
        let hash = ContentHash.make(kind: .image, parts: [png])
        let item = ClipboardItem(type: .image, plainText: "Image · \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)", hash: hash,
            sourceID: "com.apple.screencaptureui", sourceName: "Screenshot", now: capturedAt)
        return CapturedClip(item: item, imageData: png)
    }
}
