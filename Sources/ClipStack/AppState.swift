import AppKit
import SwiftUI
import Combine
import ClipStackCore

@MainActor
final class AppState: ObservableObject {
    let settings = SettingsStore()
    let storage: StorageService
    let repository: ClipboardRepository
    let watcher = ClipboardWatcher()
    let screenshots = ScreenshotWatcher()
    let paste = PasteService()
    let hotkey = HotkeyManager()
    @Published var items: [ClipboardItem] = []
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var filter: HistoryFilter = .all { didSet { scheduleSearch() } }
    @Published var selectedID: String?
    @Published var total = 0
    @Published var message: String?
    @Published var error: String?
    @Published var hasMore = false
    @Published var busy = false
    var showHistory: (() -> Void)?
    var closeHistory: (() -> Void)?
    var showSettings: (() -> Void)?
    private var searchTask: Task<Void, Never>?
    private var revision = 0
    private var pageLimit = 250
    private var cleanupTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    init() throws {
        storage = try StorageService()
        repository = try ClipboardRepository(storage: storage)
        screenshots.onCapture = { [weak self] clip in self?.save(clip) }
        screenshots.onError = { [weak self] message in self?.error = message }
        watcher.onChange = { [weak self] board in self?.capture(board) }
        settings.$paused.sink { [weak self] paused in self?.watcher.paused = paused; self?.screenshots.paused = paused }.store(in: &subscriptions)
        settings.$shortcutOption.dropFirst().sink { [weak self] value in self?.registerHotkey(value) }.store(in: &subscriptions)
        hotkey.onPress = { [weak self] in self?.showHistory?() }
        registerHotkey(settings.shortcutOption)
        startRecording()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.cleanup() }
        }
        Task { await cleanup() }
    }
    var selected: ClipboardItem? { items.first { $0.id == selectedID } }
    func startRecording() { watcher.start(); screenshots.start() }
    func stop() { watcher.stop(); screenshots.stop(); hotkey.stop(); cleanupTimer?.invalidate(); searchTask?.cancel() }
    private func registerHotkey(_ option: Bool) {
        do { try hotkey.register(useOption: option) } catch { self.error = error.localizedDescription }
    }
    private func capture(_ board: NSPasteboard) {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let changeCount = board.changeCount
        guard let clip = ClipboardParser.parse(board, sourceID: app?.bundleIdentifier,
                sourceName: app?.localizedName ?? "Unknown app", excludedApps: settings.excludedApps,
                filterSecrets: settings.filterSecrets), board.changeCount == changeCount else { return }
        save(clip)
    }
    private func save(_ clip: CapturedClip) {
        Task {
            do {
                try await repository.save(clip.item, imageData: clip.imageData)
                refresh()
            } catch { self.error = "Could not save clipboard history. \(error.localizedDescription)" }
        }
    }
    private func scheduleSearch() { pageLimit = 250; refresh(debounce: true) }
    func refresh(debounce: Bool = false) {
        searchTask?.cancel(); revision += 1
        let currentRevision = revision; let query = query; let filter = filter; let limit = pageLimit
        searchTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            do {
                // Fetch in pages; no artificial ceiling on navigable history.
                var result: [ClipboardItem] = []
                while result.count < limit + 1 {
                    let pageSize = min(1000, limit + 1 - result.count)
                    let page = try await repository.search(query, filter: filter, limit: pageSize, offset: result.count)
                    result.append(contentsOf: page)
                    if page.count < pageSize { break }
                }
                let count = try await repository.count()
                guard !Task.isCancelled, currentRevision == revision else { return }
                hasMore = result.count > limit; items = Array(result.prefix(limit)); total = count
                if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func loadMore() { pageLimit += 250; refresh() }
    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        selectedID = items[max(0, min(items.count - 1, index + delta))].id
        if index + delta >= items.count - 1 && hasMore { loadMore() }
    }
    func togglePin(_ item: ClipboardItem? = nil) {
        guard let item = item ?? selected else { return }
        Task { do { try await repository.togglePin(item.id); refresh() } catch { self.error = error.localizedDescription } }
    }
    func delete(_ item: ClipboardItem? = nil) {
        guard let item = item ?? selected else { return }
        Task { do { try await repository.delete(item.id); refresh() } catch { self.error = error.localizedDescription } }
    }
    func clear(includePinned: Bool) {
        Task {
            do { try await repository.clear(includePinned: includePinned); refresh(); message = "History cleared" }
            catch { self.error = error.localizedDescription }
        }
    }
    func cleanup() async {
        do { try await repository.cleanup(); refresh() }
        catch { self.error = error.localizedDescription }
    }
    func useSelected(copyOnly: Bool = false) {
        guard let item = selected, !busy else { return }
        do { try ClipboardWriter.write(item, storage: storage); watcher.suppressCurrentChange() }
        catch { self.error = error.localizedDescription; return }
        busy = true
        Task {
            defer { busy = false }
            do { try await repository.markUsed(item.id) } catch { self.error = error.localizedDescription }
            if copyOnly { message = "Copied to clipboard"; return }
            if !paste.isTrusted {
                message = "Copied. Press ⌘V in your app, or enable automatic paste in Settings."
                return
            }
            closeHistory?()
            if !(await paste.restoreAndPaste()) { message = "Copied. Automatic paste was unavailable; press ⌘V in your app." }
        }
    }
}
