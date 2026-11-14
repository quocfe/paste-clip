import AppKit
import ClipStackCore
import SwiftUI

private let accent = Color(red: 0.43, green: 0.36, blue: 0.89)

struct HistoryRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    var body: some View {
        HistoryView(state: state, settings: settings)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .tint(accent)
            .alert(
                "Something needs attention",
                isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })
            ) {
                Button("OK") { state.error = nil }
            } message: {
                Text(state.error ?? "")
            }
    }
}

struct HistoryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(accent)
                Text("ClipStack").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search clipboard", text: $state.query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Search clipboard history")
                    if !state.query.isEmpty {
                        Button {
                            state.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain)
                    }
                }.padding(8).frame(width: 210)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(HistoryFilter.allCases, id: \.self) { filter in
                            Button {
                                state.filter = filter
                                searchFocused = false
                            } label: {
                                Text(filter == .all ? "Clipboard history" : filter.rawValue)
                                    .font(.system(size: 12, weight: .medium)).fixedSize()
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .foregroundStyle(state.filter == filter ? Color.white : Color.secondary)
                                    .background(state.filter == filter ? accent : .clear, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("\(state.total) / \(ClipboardRepository.historyLimit)").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).fixedSize()
                Button {
                    state.showSettings?()
                } label: {
                    Image(systemName: "gearshape")
                }.help("Settings · ⌘,")
                Button {
                    state.closeHistory?()
                } label: {
                    Image(systemName: "xmark")
                }.help("Close · Esc")
            }.buttonStyle(.plain).padding(.horizontal, 22).frame(height: 54)
            if state.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: state.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(accent)
                    Text(state.query.isEmpty ? "Your clipboard, ready when you are" : "No matching clips")
                        .font(.system(size: 18, weight: .medium))
                    Text(
                        state.query.isEmpty
                            ? (settings.paused
                                ? "History is paused. Resume in Settings."
                                : "Copy text or take a screenshot. Your latest 20 clips appear here.")
                            : "Try another search or filter."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(spacing: 14) {
                            ForEach(state.items) { item in
                                ClipCard(item: item, storage: state.storage, selected: state.selectedID == item.id)
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                                    .onTapGesture(count: 2) {
                                        searchFocused = false
                                        state.selectedID = item.id
                                        state.useSelected()
                                    }
                                    .onTapGesture {
                                        searchFocused = false
                                        state.selectedID = item.id
                                    }
                                    .contextMenu {
                                        Button("Copy") {
                                            state.selectedID = item.id
                                            state.useSelected(copyOnly: true)
                                        }
                                        Button(item.isFavorite ? "Unpin" : "Pin") { state.togglePin(item) }
                                        Divider()
                                        Button("Delete", role: .destructive) { state.delete(item) }
                                    }
                                    .onDrag { dragProvider(item) }
                                    .id(item.id)
                            }
                        }.padding(.horizontal, 22).padding(.vertical, 6)
                    }
                    .onChange(of: state.selectedID) { id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            HStack(spacing: 14) {
                Circle().fill(settings.paused ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(settings.paused ? "Paused" : "Latest 20 clips · Screenshots included")
                if let message = state.message {
                    Text(message).foregroundStyle(accent).lineLimit(1)
                    Button {
                        state.message = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("← → Select   ↵ Paste   ⌘↵ Copy   Esc Close").fixedSize()
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 30)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipStackFocusSearch)) { _ in searchFocused = true }
    }
    private func dragProvider(_ item: ClipboardItem) -> NSItemProvider {
        if item.type == .image, let name = item.assetPath, let url = state.storage.assetURL(name),
            let provider = NSItemProvider(contentsOf: url)
        {
            return provider
        }
        if item.type == .file, let url = item.files.first, let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        return NSItemProvider(object: item.plainText as NSString)
    }
}

struct ClipCard: View {
    let item: ClipboardItem
    let storage: StorageService
    let selected: Bool
    @State private var thumbnail: NSImage?
    private var imageURL: URL? {
        guard item.type == .image, let name = item.assetPath else { return nil }
        return storage.assetURL(name)
    }
    private var color: Color {
        switch item.type {
        case .image: return Color(red: 0.20, green: 0.60, blue: 0.78)
        case .link: return Color(red: 0.27, green: 0.64, blue: 0.53)
        case .file: return Color(red: 0.83, green: 0.55, blue: 0.25)
        default: return Color(red: 0.36, green: 0.52, blue: 0.83)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.type.label).font(.system(size: 14, weight: .semibold))
                    Text(item.sourceAppName).font(.system(size: 10)).opacity(0.85).lineLimit(1)
                }
                Spacer()
                if item.isFavorite { Image(systemName: "pin.fill").font(.system(size: 11)) }
                SourceIcon(bundleID: item.sourceAppBundleID).frame(width: 28, height: 28)
            }.foregroundStyle(.white).padding(.horizontal, 14).frame(height: 53).background(color)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            HStack {
                Spacer()
                if selected { Image(systemName: "return").foregroundStyle(accent) }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 13).frame(height: 27)
        }
        .frame(width: 230, height: 244)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(
                selected ? accent : Color.primary.opacity(0.10), lineWidth: selected ? 3 : 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.type.label), \(item.title), from \(item.sourceAppName)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .task(id: imageURL) {
            guard let imageURL else { return }
            thumbnail = await ThumbnailCache.shared.image(for: imageURL)
        }
    }
    @ViewBuilder private var content: some View {
        if let imageURL {
            // Never decode the full-size asset while rendering; a cached thumbnail appears once loaded.
            if let image = thumbnail ?? ThumbnailCache.shared.cached(imageURL) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                Image(systemName: "photo").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if item.type == .file {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(item.files.prefix(3)), id: \.absoluteString) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(
                            width: 30, height: 30)
                        Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(2)
                    }
                }
                if item.files.count > 3 {
                    Text("+\(item.files.count - 3) more files").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        } else {
            Text(String(item.plainText.prefix(3000)))
                .font(
                    .system(
                        size: item.plainText.count < 80 ? 22 : 13,
                        weight: item.plainText.count < 80 ? .medium : .regular)
                )
                .foregroundStyle(item.type == .link ? color : Color.primary)
                .lineSpacing(3).frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
        }
    }
}

private struct SourceIcon: View {
    let bundleID: String?
    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: "doc.on.clipboard").resizable().scaledToFit().padding(3)
        }
    }
}
