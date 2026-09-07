import AppKit
import Carbon

@MainActor
final class HotkeyManager {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    func register(useOption: Bool) throws {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { manager.onPress?() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw HotkeyError.registration(status) }
        }
        let id = EventHotKeyID(signature: OSType(0x4353544B), id: 1)
        let modifiers = UInt32(cmdKey | (useOption ? optionKey : shiftKey))
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, id, GetApplicationEventTarget(), 0, &hotkey)
        guard status == noErr else { throw HotkeyError.registration(status) }
    }
    func stop() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        hotkey = nil; handler = nil
    }
}

enum HotkeyError: LocalizedError {
    case registration(OSStatus)
    var errorDescription: String? { "Could not register the global shortcut. Choose another shortcut in Settings." }
}
