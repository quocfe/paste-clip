import Foundation
import GRDB

public actor ClipboardRepository {
    public static let historyLimit = 20
    private let database: DatabaseQueue
    private let storage: StorageService

    public init(storage: StorageService, inMemory: Bool = false) throws {
        self.storage = storage
        database = try inMemory ? DatabaseQueue() : DatabaseQueue(path: storage.root.appendingPathComponent("clips.db").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE clipboard_items (
                id TEXT PRIMARY KEY NOT NULL, type TEXT NOT NULL, plainText TEXT NOT NULL,
                html BLOB, rtf BLOB, contentHash TEXT NOT NULL UNIQUE,
                sourceAppBundleID TEXT, sourceAppName TEXT NOT NULL,
                assetPath TEXT, filePaths TEXT, url TEXT,
                isFavorite BOOLEAN NOT NULL DEFAULT 0, isSensitive BOOLEAN NOT NULL DEFAULT 0,
                createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                lastUsedAt DATETIME, useCount INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX history_order ON clipboard_items(updatedAt DESC);
            CREATE INDEX history_favorites ON clipboard_items(isFavorite, updatedAt DESC);
            CREATE VIRTUAL TABLE clips_fts USING fts5(plainText, sourceAppName, url, filePaths,
                content='clipboard_items', content_rowid='rowid', tokenize='unicode61');
            CREATE TRIGGER clips_insert AFTER INSERT ON clipboard_items BEGIN
                INSERT INTO clips_fts(rowid, plainText, sourceAppName, url, filePaths)
                VALUES(new.rowid, new.plainText, new.sourceAppName, new.url, new.filePaths);
            END;
            CREATE TRIGGER clips_delete AFTER DELETE ON clipboard_items BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, plainText, sourceAppName, url, filePaths)
                VALUES('delete', old.rowid, old.plainText, old.sourceAppName, old.url, old.filePaths);
            END;
            CREATE TRIGGER clips_update AFTER UPDATE ON clipboard_items BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, plainText, sourceAppName, url, filePaths)
                VALUES('delete', old.rowid, old.plainText, old.sourceAppName, old.url, old.filePaths);
                INSERT INTO clips_fts(rowid, plainText, sourceAppName, url, filePaths)
                VALUES(new.rowid, new.plainText, new.sourceAppName, new.url, new.filePaths);
            END;
            """)
        }
        try migrator.migrate(database)
        try database.write { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try Self.enforceLimit(db)
        }
        let names = try database.read { try String.fetchAll($0, sql: "SELECT assetPath FROM clipboard_items WHERE assetPath IS NOT NULL") }
        try storage.removeOrphans(keeping: Set(names))
    }

    public func save(_ incoming: ClipboardItem, imageData: Data? = nil) throws {
        var item = incoming
        if let imageData { item.assetPath = try storage.storeImage(imageData, hash: item.contentHash) }
        try database.write { db in
            if let existing = try ClipboardItem.fetchOne(db, sql: "SELECT * FROM clipboard_items WHERE contentHash = ?", arguments: [item.contentHash]) {
                item.id = existing.id; item.createdAt = existing.createdAt
                item.isFavorite = existing.isFavorite; item.lastUsedAt = existing.lastUsedAt
                item.useCount = existing.useCount + 1
                // Spotlight can deliver a screenshot after the same image was copied again.
                if existing.updatedAt > item.updatedAt {
                    item.updatedAt = existing.updatedAt
                    item.sourceAppBundleID = existing.sourceAppBundleID
                    item.sourceAppName = existing.sourceAppName
                }
            }
            try item.save(db)
            try Self.enforceLimit(db)
        }
        try cleanAssets()
    }

    public static func searchPattern(_ query: String) -> String? {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(32).map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    public func search(_ query: String = "", filter: HistoryFilter = .all, limit: Int = 250, offset: Int = 0) throws -> [ClipboardItem] {
        try database.read { db in
            var clauses: [String] = []; var arguments = StatementArguments()
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let pattern = Self.searchPattern(query) else { return [] }
                clauses.append("rowid IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
                arguments += [pattern]
            }
            switch filter {
            case .all: break
            case .pinned: clauses.append("isFavorite = 1")
            case .images: clauses.append("type = 'image'")
            case .links: clauses.append("type = 'link'")
            case .files: clauses.append("type = 'file'")
            }
            let condition = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            arguments += [max(1, min(limit, 1000)), max(0, offset)]
            return try ClipboardItem.fetchAll(db, sql: "SELECT * FROM clipboard_items\(condition) ORDER BY updatedAt DESC, rowid DESC LIMIT ? OFFSET ?", arguments: arguments)
        }
    }

    public func count() throws -> Int { try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0 } }
    public func togglePin(_ id: String) throws {
        try database.write { try $0.execute(sql: "UPDATE clipboard_items SET isFavorite = NOT isFavorite WHERE id = ?", arguments: [id]) }
    }
    public func markUsed(_ id: String) throws {
        try database.write { try $0.execute(sql: "UPDATE clipboard_items SET lastUsedAt = ?, useCount = useCount + 1 WHERE id = ?", arguments: [Date(), id]) }
    }
    public func delete(_ id: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id]) }
        try cleanAssets()
    }
    public func clear(includePinned: Bool = false) throws {
        try database.write { try $0.execute(sql: "DELETE FROM clipboard_items" + (includePinned ? "" : " WHERE isFavorite = 0")) }
        try cleanAssets()
    }
    public func cleanup() throws {
        try database.write { try Self.enforceLimit($0) }
        try cleanAssets()
    }
    private static func enforceLimit(_ db: Database) throws {
        // One shared budget for every type, including pinned clips. Ties use insertion order.
        try db.execute(sql: "DELETE FROM clipboard_items WHERE id IN (SELECT id FROM clipboard_items ORDER BY updatedAt DESC, rowid DESC LIMIT -1 OFFSET ?)", arguments: [historyLimit])
    }
    private func cleanAssets() throws {
        let names = try database.read { try String.fetchAll($0, sql: "SELECT assetPath FROM clipboard_items WHERE assetPath IS NOT NULL") }
        try storage.removeOrphans(keeping: Set(names))
    }
}
