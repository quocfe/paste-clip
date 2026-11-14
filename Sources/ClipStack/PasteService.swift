import AppKit
import ApplicationServices

@MainActor
final class PasteService {
    private(set) var previousApp: NSRunningApplication?
    var isTrusted: Bool { AXIsProcessTrusted() }
    func rememberTarget() {
        if let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previousApp = app
        }
    }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func restoreAndPaste() async -> Bool {
        guard let target = previousApp, !target.isTerminated else { return false }
        guard target.activate(options: [.activateIgnoringOtherApps]) else { return false }
        guard isTrusted else { return false }
        // Wait for focus to move; never send Cmd+V to an unrelated frontmost app.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled else { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                // Allow the shortcut's modifier keys to be released before synthesizing paste.
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if !flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty { continue }
                guard let source = CGEventSource(stateID: .privateState),
                    let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
                else { return false }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.postToPid(target.processIdentifier)
                up.postToPid(target.processIdentifier)
                return true
            }
        }
        return false
    }
}
