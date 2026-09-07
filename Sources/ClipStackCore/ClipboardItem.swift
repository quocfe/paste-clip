import Foundation
import CryptoKit
import GRDB

public enum ClipKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case text, link, richText, image, file
    public var label: String {
        switch self { case .text: return "Text"; case .link: return "Link"; case .richText: return "Rich text"; case .image: return "Image"; case .file: return "Files" }
    }
    public var symbol: String {
        switch self { case .text: return "text.alignleft"; case .link: return "link"; case .richText: return "textformat"; case .image: return "photo"; case .file: return "doc" }
    }
}

public enum HistoryFilter: String, CaseIterable, Sendable {
    case all = "All", pinned = "Pinned", images = "Images", links = "Links", files = "Files"
}

public struct ClipboardItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "clipboard_items"
    public var id: String
    public var type: ClipKind
    public var plainText: String
    public var html: Data?
    public var rtf: Data?
    public var contentHash: String
    public var sourceAppBundleID: String?
    public var sourceAppName: String
    public var assetPath: String?
    public var filePaths: String?
    public var url: String?
    public var isFavorite: Bool
    public var isSensitive: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(type: ClipKind, plainText: String, hash: String, sourceID: String? = nil,
                sourceName: String = "Unknown app", html: Data? = nil, rtf: Data? = nil,
                assetPath: String? = nil, filePaths: String? = nil, url: String? = nil,
                now: Date = Date()) {
        id = UUID().uuidString; self.type = type; self.plainText = plainText
        contentHash = hash; sourceAppBundleID = sourceID; sourceAppName = sourceName
        self.html = html; self.rtf = rtf; self.assetPath = assetPath
        self.filePaths = filePaths; self.url = url; isFavorite = false; isSensitive = false
        createdAt = now; updatedAt = now; useCount = 1
    }

    public var files: [URL] {
        guard let filePaths, let data = filePaths.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths.compactMap(URL.init(string:))
    }
    public var title: String {
        return plainText.prefix(180).split(whereSeparator: \.isNewline).first.map(String.init) ?? type.label
    }
}

public enum ContentHash {
    // Length prefixes prevent ambiguous combinations and preserve rich representations.
    public static func make(kind: ClipKind, parts: [Data]) -> String {
        var hash = SHA256()
        hash.update(data: Data(kind.rawValue.utf8))
        for part in parts {
            hash.update(data: Data("\(part.count):".utf8))
            hash.update(data: part)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
