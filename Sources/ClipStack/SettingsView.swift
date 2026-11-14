import AppKit
import ClipStackCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum LoginService {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @State private var loginEnabled = LoginService.enabled
    @State private var trusted = false
    @State private var clearConfirmation = false
    @State private var includePinned = false
    var body: some View {
        Form {
            Section {
                Toggle(
                    "Launch ClipStack at login",
                    isOn: Binding(
                        get: { loginEnabled },
                        set: { value in
                            do {
                                try LoginService.setEnabled(value)
                                loginEnabled = LoginService.enabled
                            } catch { state.error = error.localizedDescription }
                        }))
                Picker("Global shortcut", selection: $settings.shortcutOption) {
                    Text("⌘ ⇧ V").tag(false)
                    Text("⌘ ⌥ V").tag(true)
                }
                Toggle("Pause clipboard history", isOn: $settings.paused)
            } header: {
                Text("General")
            }
            Section {
                HStack {
                    Label(
                        trusted ? "Automatic paste is enabled" : "Accessibility permission is optional",
                        systemImage: trusted ? "checkmark.shield" : "hand.raised")
                    Spacer()
                    Button(trusted ? "Open System Settings" : "Enable") {
                        if trusted {
                            NSWorkspace.shared.open(
                                URL(
                                    string:
                                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        } else {
                            state.paste.requestPermission()
                        }
                    }
                }
                Text("Without permission, Enter copies the selected clip. Paste it in your app with ⌘V.").font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Paste")
            }
            Section {
                LabeledContent("Maximum clips", value: "\(ClipboardRepository.historyLimit)")
                Text(
                    "Text, images, links, and files share the same 20 slots. Adding a new clip removes the oldest, even if pinned."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Import saved macOS screenshots", isOn: $settings.importScreenshots)
                Text(
                    "When on, ClipStack watches your Desktop and screenshot folder for new screenshots, which may require folder access. Screenshots copied to the clipboard are always captured. macOS saves a screenshot only after its floating thumbnail disappears; for instant import, press ⌘⇧5 → Options and turn off Show Floating Thumbnail."
                )
                .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("History")
            }
            Section {
                Toggle("Skip likely passwords, API keys, tokens, and OTPs", isOn: $settings.filterSecrets)
                Text(
                    "Detection is a best-effort text filter and may skip ordinary numbers. It cannot detect secrets inside images or every password format. Marked private clips are always skipped."
                )
                .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Do not record from").font(.subheadline.weight(.medium))
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(settings.excludedApps, id: \.self) { bundle in
                                HStack {
                                    Text(bundle).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                    Spacer()
                                    Button {
                                        settings.excludedApps.removeAll { $0 == bundle }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }.buttonStyle(.plain).help("Remove exclusion")
                                }
                            }
                        }
                    }.frame(height: 80)
                    Button("Add Application…", action: addApplication)
                }
            } header: {
                Text("Privacy")
            }
            Section {
                HStack {
                    Button("Show local storage") { NSWorkspace.shared.open(state.storage.root) }
                    Spacer()
                    Button("Clear history…", role: .destructive) { clearConfirmation = true }
                }
                Toggle("Include pinned clips when clearing", isOn: $includePinned)
                Text(
                    "No account. No analytics. No cloud. History is stored in your macOS user folder and is not encrypted by ClipStack."
                )
                .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Your data")
            }
        }
        .formStyle(.grouped).frame(width: 590, height: 650)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .alert("Delete \(includePinned ? "all" : "unpinned") clipboard history?", isPresented: $clearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { state.clear(includePinned: includePinned) }
        } message: {
            Text(
                "Saved clips and their images will be removed. This cannot be undone. Original files and the current system clipboard are not deleted."
            )
        }
        .alert(
            "Something needs attention",
            isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })
        ) {
            Button("OK") { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }
    private func refreshPermissions() {
        trusted = state.paste.isTrusted
        loginEnabled = LoginService.enabled
    }
    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let id = Bundle(url: url)?.bundleIdentifier, !settings.excludedApps.contains(id) {
                    settings.excludedApps.append(id)
                }
            }
        }
    }
}
