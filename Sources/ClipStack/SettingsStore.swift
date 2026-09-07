import SwiftUI
import ClipStackCore

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    @Published var maxItems: Int { didSet { defaults.set(maxItems, forKey: "maxItems") } }
    @Published var filterSecrets: Bool { didSet { defaults.set(filterSecrets, forKey: "filterSecrets") } }
    @Published var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    @Published var shortcutOption: Bool { didSet { defaults.set(shortcutOption, forKey: "shortcutOption") } }
    var shortcutLabel: String { shortcutOption ? "⌘ ⌥ V" : "⌘ ⇧ V" }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["retentionDays": 30, "maxItems": 10000, "filterSecrets": true,
                                     "excludedApps": PrivacyFilter.defaultExcludedApps])
        retentionDays = defaults.integer(forKey: "retentionDays"); maxItems = defaults.integer(forKey: "maxItems")
        filterSecrets = defaults.bool(forKey: "filterSecrets"); excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        paused = defaults.bool(forKey: "paused"); onboarded = defaults.bool(forKey: "onboarded")
        shortcutOption = defaults.bool(forKey: "shortcutOption")
    }
}
