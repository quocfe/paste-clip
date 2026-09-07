import SwiftUI
import AppKit
import ClipStackCore

private let accent = Color(red: 0.43, green: 0.36, blue: 0.89)

struct HistoryRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Group {
            if settings.onboarded { HistoryView(state: state, settings: settings) }
            else { WelcomeView(state: state, settings: settings) }
        }
        .frame(width: 920, height: 610)
        .background(.regularMaterial)
        .tint(accent)
        .alert("Something needs attention", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("OK") { state.error = nil }
        } message: { Text(state.error ?? "") }
    }
}

struct HistoryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 20)).foregroundStyle(accent)
                Text("ClipStack").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("A little less copying. A lot more flow.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(settings.paused ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(settings.paused ? "Paused" : "Local only").font(.system(size: 11, weight: .medium))
                }.foregroundStyle(.secondary)
                Button { state.showSettings?() } label: { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.plain).help("Settings · ⌘,")
            }.padding(.horizontal, 24).padding(.top, 23).padding(.bottom, 20)
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").foregroundStyle(accent).font(.system(size: 19))
                TextField("Search your clipboard…", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 18)).focused($searchFocused)
                    .accessibilityLabel("Search clipboard history")
                if !state.query.isEmpty {
                    Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
                KeyCap(text: "⌘ F")
            }.padding(16).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.15), lineWidth: 1)).padding(.horizontal, 22)
            HStack(spacing: 5) {
                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                    Button { state.filter = filter } label: {
                        HStack(spacing: 5) {
                            if filter == .pinned { Image(systemName: "pin") }
                            Text(filter.rawValue)
                        }.font(.system(size: 12, weight: state.filter == filter ? .semibold : .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(state.filter == filter ? accent : Color.secondary)
                            .background(state.filter == filter ? accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("\(state.total.formatted()) clips").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 22).padding(.vertical, 13)
            Divider()
            HStack(spacing: 0) {
                historyList.frame(width: 470)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = state.message {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                    Text(message).font(.system(size: 11))
                    Spacer()
                    Button { state.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(accent.opacity(0.08))
            }
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 5) { KeyCap(text: "↑ ↓"); Text("Navigate") }
                HStack(spacing: 5) { KeyCap(text: "⌘ P"); Text("Pin") }
                HStack(spacing: 5) { KeyCap(text: "⌘ ↵"); Text("Copy") }
                Spacer()
                Button { state.useSelected() } label: {
                    HStack(spacing: 8) { Text(state.paste.isTrusted ? "Paste clip" : "Copy clip"); KeyCap(text: "↵") }
                }.buttonStyle(.plain).foregroundStyle(accent).disabled(state.selected == nil || state.busy)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 13)
        }
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .clipStackFocusSearch)) { _ in searchFocused = true }
    }

    private var historyList: some View {
        Group {
            if state.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: state.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 32, weight: .light)).foregroundStyle(accent.opacity(0.65))
                    Text(state.query.isEmpty ? "Your next copy starts here" : "No matching clips").font(.system(size: 15, weight: .semibold))
                    Text(state.query.isEmpty ? (settings.paused ? "Resume history to capture new clips." : "Copy text, a link, an image, or a file.\nIt will be waiting here when you need it.") : "Try a different keyword or filter.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            HStack {
                                Text(state.query.isEmpty ? "RECENT CLIPS" : "SEARCH RESULTS").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                                Spacer()
                            }.foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 6)
                            ForEach(state.items) { item in
                                ClipRow(item: item, selected: state.selectedID == item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { state.selectedID = item.id; state.useSelected() }
                                    .onTapGesture { state.selectedID = item.id }
                                    .contextMenu {
                                        Button("Copy") { state.selectedID = item.id; state.useSelected(copyOnly: true) }
                                        Button(item.isFavorite ? "Unpin" : "Pin") { state.togglePin(item) }
                                        Divider()
                                        Button("Delete", role: .destructive) { state.delete(item) }
                                    }
                                    .onDrag { dragProvider(item) }
                                    .id(item.id)
                            }
                            if state.hasMore { Button("Load more clips") { state.loadMore() }.buttonStyle(.plain).foregroundStyle(accent).padding(12) }
                        }.padding(10)
                    }.onChange(of: state.selectedID) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }
    @ViewBuilder private var preview: some View {
        if let clip = state.selected { ClipPreview(item: clip, storage: state.storage, onPin: { state.togglePin() }, onDelete: { state.delete() }) }
        else {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 42, weight: .ultraLight))
                Text("Everything you copied.\nRight where you need it.").font(.system(size: 13)).multilineTextAlignment(.center)
            }.foregroundStyle(.tertiary)
        }
    }
    private func dragProvider(_ item: ClipboardItem) -> NSItemProvider {
        if item.type == .image, let name = item.assetPath, let url = state.storage.assetURL(name), let provider = NSItemProvider(contentsOf: url) { return provider }
        if item.type == .file, let url = item.files.first, let provider = NSItemProvider(contentsOf: url) { return provider }
        return NSItemProvider(object: item.plainText as NSString)
    }
}

private struct ClipRow: View {
    let item: ClipboardItem
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? accent : Color.secondary)
                .frame(width: 36, height: 38).background(selected ? accent.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                HStack(spacing: 5) {
                    SourceIcon(bundleID: item.sourceAppBundleID).frame(width: 12, height: 12)
                    Text(item.sourceAppName)
                    Text("·")
                    Text(item.updatedAt, style: .relative)
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isFavorite { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(accent) }
            if selected { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(accent.opacity(0.65)) }
        }.padding(.horizontal, 12).padding(.vertical, 11)
            .background(selected ? accent.opacity(0.085) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent.opacity(0.17) : Color.clear, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SourceIcon: View {
    let bundleID: String?
    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else { Image(systemName: "app").resizable().scaledToFit() }
    }
}

private struct ClipPreview: View {
    let item: ClipboardItem
    let storage: StorageService
    let onPin: () -> Void
    let onDelete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("PREVIEW").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                Spacer()
                Text(item.type.label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(accent).padding(.horizontal, 8).padding(.vertical, 5).background(accent.opacity(0.08), in: Capsule())
            }
            ScrollView {
                Group {
                    if item.type == .image, let name = item.assetPath, let url = storage.assetURL(name), let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 9))
                    } else if item.type == .file {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(item.files, id: \.absoluteString) { url in
                                HStack(alignment: .top) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                        Text(url.path).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    } else {
                        Text(String(item.plainText.prefix(50000))).font(.system(size: 13, design: .monospaced))
                            .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                        if item.plainText.count > 50000 { Text("Preview truncated. Copy preserves the complete clip.").font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).frame(maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            VStack(spacing: 9) {
                metadata("Copied from", item.sourceAppName)
                metadata("Captured", item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                metadata("Size", item.type == .image ? item.plainText : "\(item.plainText.count.formatted()) characters")
                metadata("Copies & uses", String(item.useCount))
            }
            HStack(spacing: 14) {
                Button(action: onPin) { Label(item.isFavorite ? "Unpin" : "Pin clip", systemImage: item.isFavorite ? "pin.slash" : "pin") }
                if let link = item.url, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open link", systemImage: "arrow.up.right") }
                }
                Spacer()
                Button(action: onDelete) { Image(systemName: "trash") }.help("Delete clip · ⌘D")
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(22)
    }
    private func metadata(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.tertiary); Spacer(); Text(value).foregroundStyle(.secondary).lineLimit(1) }.font(.system(size: 10))
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

private struct WelcomeView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @State private var login = false
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 48, weight: .light)).foregroundStyle(accent)
                .frame(width: 96, height: 96).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 26))
            VStack(spacing: 10) {
                Text("A second home for your clipboard.").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Copy once. Find it anytime. Keep your flow.").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 17) {
                Label("Text, links, images, and files — saved only on this Mac", systemImage: "internaldrive")
                Label("Password apps and marked private clips are skipped", systemImage: "lock.shield")
                Label("History expires after 30 days. Pinned clips stay.", systemImage: "clock.arrow.circlepath")
            }.font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Picker("Open with", selection: $settings.shortcutOption) {
                    Text("⌘ ⇧ V").tag(false); Text("⌘ ⌥ V").tag(true)
                }.frame(width: 200)
                Toggle("Launch at login", isOn: $login).toggleStyle(.checkbox)
            }.font(.system(size: 12))
            HStack(spacing: 12) {
                Button("Enable automatic paste") { state.paste.requestPermission() }.controlSize(.large)
                Button("Start using ClipStack") {
                    if login { do { try LoginService.setEnabled(true) } catch { state.error = error.localizedDescription } }
                    state.startRecording()
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            Text("Automatic paste is optional. You can always copy and press ⌘V yourself.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }.padding(40)
    }
}
