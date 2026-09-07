import SwiftUI
import AppKit

@main
struct ClipStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var state: AppState?
    private var statusItem: NSStatusItem?
    private var panel: HistoryPanel?
    private var settingsWindow: NSWindow?
    private var keyboardMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let state = try AppState(); self.state = state
            state.showHistory = { [weak self] in self?.toggleHistory() }
            state.closeHistory = { [weak self] in self?.panel?.orderOut(nil) }
            state.showSettings = { [weak self] in self?.openSettings() }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "ClipStack")
            let menu = NSMenu(); menu.delegate = self; item.menu = menu; statusItem = item
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handleKey(event) == nil
                }
                return consumed ? nil : event
            }
            if !state.settings.onboarded || state.error != nil { openHistory() }
        } catch {
            let alert = NSAlert(); alert.messageText = "ClipStack could not start"
            alert.informativeText = "Your history has not been changed. \(error.localizedDescription)"
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        state?.stop()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let state else { return }; menu.removeAllItems()
        add("Open ClipStack", #selector(openHistory), to: menu)
        menu.addItem(.separator())
        add(state.settings.paused ? "Resume Clipboard History" : "Pause Clipboard History", #selector(togglePause), to: menu)
        add("Clear History…", #selector(confirmClear), to: menu)
        add("Settings…", #selector(openSettings), to: menu, key: ",")
        add("Launch at Login", #selector(toggleLogin), to: menu)
        menu.items.last?.state = LoginService.enabled ? .on : .off
        menu.addItem(.separator())
        add("Quit ClipStack", #selector(quit), to: menu, key: "q")
    }
    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    private func toggleHistory() {
        if panel?.isVisible == true && panel?.isKeyWindow == true { panel?.orderOut(nil) } else { openHistory() }
    }
    @objc private func openHistory() {
        guard let state else { return }
        state.paste.rememberTarget()
        if panel == nil {
            let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 610),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "ClipStack"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: HistoryRootView(state: state, settings: state.settings))
            self.panel = panel
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: area.midX - 460, y: area.midY - 275))
        }
        state.refresh(); NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .clipStackFocusSearch, object: nil)
    }
    @objc private func togglePause() { state?.settings.paused.toggle() }
    @objc private func toggleLogin() {
        do { try LoginService.setEnabled(!LoginService.enabled) }
        catch { state?.error = error.localizedDescription; openSettings() }
    }
    @objc private func confirmClear() {
        let alert = NSAlert(); alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Unpinned clips and their saved images will be deleted. Pinned clips will be kept."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear History")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { state?.clear(includePinned: false) }
    }
    @objc private func openSettings() {
        guard let state else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClipStack Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(state: state, settings: state.settings))
            window.center(); settingsWindow = window
        }
        panel?.orderOut(nil); NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let state, panel?.isKeyWindow == true else { return event }
        if event.keyCode == 53 { panel?.orderOut(nil); return nil }
        guard state.settings.onboarded else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p": state.togglePin(); return nil
            case "d": state.delete(); return nil
            case ",": openSettings(); return nil
            case "f": NotificationCenter.default.post(name: .clipStackFocusSearch, object: nil); return nil
            default: break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 { state.useSelected(copyOnly: modifiers.contains(.command)); return nil }
        if modifiers.intersection([.command, .option, .control, .shift]).isEmpty {
            if event.keyCode == 125 { state.moveSelection(1); return nil }
            if event.keyCode == 126 { state.moveSelection(-1); return nil }
        }
        return event
    }
}

extension Notification.Name { static let clipStackFocusSearch = Notification.Name("ClipStack.focusSearch") }
