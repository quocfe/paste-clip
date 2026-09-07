import AppKit

public struct CapturedClip: Sendable {
    public var item: ClipboardItem
    public var imageData: Data?
}

@MainActor
public enum ClipboardParser {
    public static let ownMarker = NSPasteboard.PasteboardType("com.quocfe.ClipStack.restored")
    public static let maxPayloadBytes = 20 * 1024 * 1024

    public static func parse(_ board: NSPasteboard, sourceID: String?, sourceName: String,
                             excludedApps: [String], filterSecrets: Bool) -> CapturedClip? {
        guard !excludedApps.contains(sourceID ?? "") else { return nil }
        let types = (board.types ?? []) + (board.pasteboardItems ?? []).flatMap { $0.types }
        guard !types.contains(ownMarker), !PrivacyFilter.hasPrivateMarker(types.map(\.rawValue)) else { return nil }
        var kind: ClipKind; var text = ""; var imageData: Data?
        var html: Data?; var rtf: Data?; var filePaths: String?; var link: String?
        var parts: [Data] = []

        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            kind = .file
            text = files.map(\.lastPathComponent).joined(separator: "\n")
            guard let encoded = try? JSONEncoder().encode(files.map(\.absoluteString)) else { return nil }
            filePaths = String(data: encoded, encoding: .utf8); parts = [encoded]
        } else if types.contains(.png) || types.contains(.tiff) {
            kind = .image
            guard let raw = board.data(forType: .png) ?? board.data(forType: .tiff), raw.count <= maxPayloadBytes,
                  let bitmap = NSBitmapImageRep(data: raw),
                  bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= 40_000_000,
                  let png = bitmap.representation(using: .png, properties: [:]), png.count <= maxPayloadBytes else { return nil }
            imageData = png; parts = [png]
            text = "Image · \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)"
        } else {
            html = board.data(forType: .html); rtf = board.data(forType: .rtf)
            guard (html?.count ?? 0) + (rtf?.count ?? 0) <= maxPayloadBytes else { return nil }
            text = board.string(forType: .string) ?? board.string(forType: .URL) ?? ""
            if text.isEmpty, let rtf {
                text = (try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string) ?? ""
            }
            // Do not parse HTML: external resources must never be fetched by previews.
            guard !text.isEmpty || html != nil else { return nil }
            guard text.utf8.count <= maxPayloadBytes else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, !trimmed.contains(where: \.isWhitespace) {
                kind = .link; link = trimmed
            } else { kind = html != nil || rtf != nil ? .richText : .text }
            if filterSecrets {
                guard !PrivacyFilter.looksSensitive(text),
                      !PrivacyFilter.looksSensitive(html.flatMap { String(data: $0, encoding: .utf8) } ?? "") else { return nil }
                // Without searchable text, secret filtering cannot inspect the rich payload.
                if text.isEmpty { return nil }
            }
            parts = [Data(text.utf8), html ?? Data(), rtf ?? Data()]
        }
        guard parts.reduce(0, { $0 + $1.count }) <= maxPayloadBytes else { return nil }
        let hash = ContentHash.make(kind: kind, parts: parts)
        let item = ClipboardItem(type: kind, plainText: text, hash: hash, sourceID: sourceID,
                                 sourceName: sourceName, html: html, rtf: rtf, filePaths: filePaths, url: link)
        return CapturedClip(item: item, imageData: imageData)
    }
}

@MainActor
public final class ClipboardWatcher {
    private let board: NSPasteboard
    private var changeCount: Int
    private var timer: Timer?
    public var onChange: ((NSPasteboard) -> Void)?
    public var paused = false {
        didSet { changeCount = board.changeCount }
    }
    public init(board: NSPasteboard = .general) { self.board = board; changeCount = board.changeCount }
    public func start() {
        guard timer == nil else { return }
        changeCount = board.changeCount
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    public func stop() { timer?.invalidate(); timer = nil }
    public func poll() {
        let current = board.changeCount
        guard current != changeCount else { return }
        changeCount = current
        if !paused { onChange?(board) }
    }
    public func suppressCurrentChange() { changeCount = board.changeCount }
}
