import SwiftUI
import ClipStackCore

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var filterSecrets: Bool { didSet { defaults.set(filterSecrets, forKey: "filterSecrets") } }
    @Published var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    @Published var shortcutOption: Bool { didSet { defaults.set(shortcutOption, forKey: "shortcutOption") } }
    var shortcutLabel: String { shortcutOption ? "⌘ ⌥ V" : "⌘ ⇧ V" }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["filterSecrets": true,
                                     "excludedApps": PrivacyFilter.defaultExcludedApps])
        filterSecrets = defaults.bool(forKey: "filterSecrets"); excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        paused = defaults.bool(forKey: "paused")
        shortcutOption = defaults.bool(forKey: "shortcutOption")
    }
}
