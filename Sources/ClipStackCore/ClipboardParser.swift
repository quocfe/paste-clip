import AppKit

public struct CapturedClip: Sendable {
    public var item: ClipboardItem
    public var imageData: Data?
}

/// Raw image bytes read from the pasteboard. Decoding and PNG encoding are deferred so they
/// can run away from the main actor.
public struct PendingImage: Sendable {
    public var raw: Data
    public var sourceID: String?
    public var sourceName: String
    public var capturedAt: Date
}

public enum SkipReason: Sendable, Equatable {
    case excludedApp, privateContent, likelySecret, unsupported, tooLarge
}

public enum ClipboardReading: Sendable {
    case clip(CapturedClip)
    case image(PendingImage)
    case skipped(SkipReason)
}

/// Decodes any bitmap format and normalizes it to PNG. Safe to call from any thread.
public enum ImageNormalizer {
    public static let maxPixels = 40_000_000.0

    public static func clip(from raw: Data, sourceID: String?, sourceName: String, capturedAt: Date) -> CapturedClip? {
        guard raw.count <= ClipboardParser.maxPayloadBytes,
            let bitmap = NSBitmapImageRep(data: raw),
            bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
            Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= maxPixels,
            let png = bitmap.representation(using: .png, properties: [:]),
            png.count <= ClipboardParser.maxPayloadBytes
        else { return nil }
        let item = ClipboardItem(
            type: .image, plainText: "Image · \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)",
            hash: ContentHash.make(kind: .image, parts: [png]),
            sourceID: sourceID, sourceName: sourceName, now: capturedAt)
        return CapturedClip(item: item, imageData: png)
    }

    public static func clip(from pending: PendingImage) -> CapturedClip? {
        clip(
            from: pending.raw, sourceID: pending.sourceID, sourceName: pending.sourceName,
            capturedAt: pending.capturedAt)
    }
}

@MainActor
public enum ClipboardParser {
    public static let ownMarker = NSPasteboard.PasteboardType("com.quocfe.ClipStack.restored")
    nonisolated public static let maxPayloadBytes = 20 * 1024 * 1024

    /// Synchronous convenience that also normalizes images. The app uses `read` instead and
    /// normalizes images off the main actor.
    public static func parse(
        _ board: NSPasteboard, sourceID: String?, sourceName: String,
        excludedApps: [String], filterSecrets: Bool
    ) -> CapturedClip? {
        switch read(
            board, sourceID: sourceID, sourceName: sourceName,
            excludedApps: excludedApps, filterSecrets: filterSecrets)
        {
        case .clip(let clip): return clip
        case .image(let pending): return ImageNormalizer.clip(from: pending)
        case .skipped: return nil
        }
    }

    public static func read(
        _ board: NSPasteboard, sourceID: String?, sourceName: String,
        excludedApps: [String], filterSecrets: Bool
    ) -> ClipboardReading {
        guard !excludedApps.contains(sourceID ?? "") else { return .skipped(.excludedApp) }
        let types = (board.types ?? []) + (board.pasteboardItems ?? []).flatMap { $0.types }
        guard !types.contains(ownMarker), !PrivacyFilter.hasPrivateMarker(types.map(\.rawValue)) else {
            return .skipped(.privateContent)
        }

        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !files.isEmpty
        {
            guard let encoded = try? JSONEncoder().encode(files.map(\.absoluteString)) else {
                return .skipped(.unsupported)
            }
            guard encoded.count <= maxPayloadBytes else { return .skipped(.tooLarge) }
            let item = ClipboardItem(
                type: .file, plainText: files.map(\.lastPathComponent).joined(separator: "\n"),
                hash: ContentHash.make(kind: .file, parts: [encoded]), sourceID: sourceID,
                sourceName: sourceName, filePaths: String(data: encoded, encoding: .utf8))
            return .clip(CapturedClip(item: item, imageData: nil))
        }

        let plain = board.string(forType: .string) ?? ""
        // Office-style apps attach a rendered picture to copied text. Text with an RTF
        // representation is treated as text; a picture copied on its own carries no RTF.
        let isTextWithRendering =
            types.contains(.rtf) && !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if (types.contains(.png) || types.contains(.tiff)) && !isTextWithRendering {
            guard let raw = board.data(forType: .png) ?? board.data(forType: .tiff) else {
                return .skipped(.unsupported)
            }
            guard raw.count <= maxPayloadBytes else { return .skipped(.tooLarge) }
            return .image(
                PendingImage(raw: raw, sourceID: sourceID, sourceName: sourceName, capturedAt: Date()))
        }

        let html = board.data(forType: .html)
        let rtf = board.data(forType: .rtf)
        guard (html?.count ?? 0) + (rtf?.count ?? 0) <= maxPayloadBytes else { return .skipped(.tooLarge) }
        var text = plain.isEmpty ? (board.string(forType: .URL) ?? "") : plain
        if text.isEmpty, let rtf {
            text =
                (try? NSAttributedString(
                    data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                ).string) ?? ""
        }
        // Do not parse HTML: external resources must never be fetched by previews.
        guard !text.isEmpty || html != nil else { return .skipped(.unsupported) }
        guard text.utf8.count <= maxPayloadBytes else { return .skipped(.tooLarge) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind: ClipKind = html != nil || rtf != nil ? .richText : .text
        var link: String?
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, !trimmed.contains(where: \.isWhitespace)
        {
            kind = .link
            link = trimmed
        }
        if filterSecrets {
            let markup = html.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard !PrivacyFilter.looksSensitive(text), !PrivacyFilter.looksSensitive(markup) else {
                return .skipped(.likelySecret)
            }
            // Without searchable text, secret filtering cannot inspect the rich payload.
            if text.isEmpty { return .skipped(.unsupported) }
        }
        let parts = [Data(text.utf8), html ?? Data(), rtf ?? Data()]
        guard parts.reduce(0, { $0 + $1.count }) <= maxPayloadBytes else { return .skipped(.tooLarge) }
        let item = ClipboardItem(
            type: kind, plainText: text, hash: ContentHash.make(kind: kind, parts: parts),
            sourceID: sourceID, sourceName: sourceName, html: html, rtf: rtf, url: link)
        return .clip(CapturedClip(item: item, imageData: nil))
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
    public init(board: NSPasteboard = .general) {
        self.board = board
        changeCount = board.changeCount
    }
    public func start() {
        guard timer == nil else { return }
        changeCount = board.changeCount
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    public func stop() {
        timer?.invalidate()
        timer = nil
    }
    public func poll() {
        let current = board.changeCount
        guard current != changeCount else { return }
        changeCount = current
        if !paused { onChange?(board) }
    }
    public func suppressCurrentChange() { changeCount = board.changeCount }
}
