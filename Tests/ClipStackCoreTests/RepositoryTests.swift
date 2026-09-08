import XCTest
import GRDB
@testable import ClipStackCore

final class RepositoryTests: XCTestCase {
    private func setupStore() throws -> (ClipboardRepository, StorageService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipStackTests-" + UUID().uuidString)
        let storage = try StorageService(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try ClipboardRepository(storage: storage), storage)
    }
    private func clip(_ text: String, now: Date = Date()) -> ClipboardItem {
        ClipboardItem(type: .text, plainText: text, hash: ContentHash.make(kind: .text, parts: [Data(text.utf8)]), sourceName: "Terminal", now: now)
    }

    func testDeduplicationPreservesIdentityAndPin() async throws {
        let (repo, _) = try setupStore()
        let first = clip("docker compose up -d", now: Date(timeIntervalSince1970: 100))
        try await repo.save(first)
        try await repo.togglePin(first.id)
        try await repo.save(clip(first.plainText, now: Date(timeIntervalSince1970: 200)))
        let result = try await repo.search()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, first.id)
        XCTAssertTrue(result[0].isFavorite)
        XCTAssertEqual(result[0].createdAt, first.createdAt)
        XCTAssertEqual(result[0].updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(result[0].useCount, 2)
    }
    func testDelayedDuplicateDoesNotMoveRecentCopyBackwards() async throws {
        let (repo, _) = try setupStore()
        try await repo.save(clip("same image", now: Date(timeIntervalSince1970: 200)))
        try await repo.save(clip("same image", now: Date(timeIntervalSince1970: 100)))
        let result = try await repo.search()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.updatedAt, Date(timeIntervalSince1970: 200))
    }
    func testFTSSearchAndTriggers() async throws {
        let (repo, _) = try setupStore()
        let item = clip("docker compose up -d")
        try await repo.save(item)
        let prefix = try await repo.search("dock comp")
        let source = try await repo.search("terminal")
        let punctuation = try await repo.search("\" OR *")
        XCTAssertEqual(prefix.map(\.id), [item.id]); XCTAssertEqual(source.count, 1)
        XCTAssertTrue(punctuation.isEmpty)
        try await repo.togglePin(item.id)
        let pinned = try await repo.search("docker", filter: .pinned)
        XCTAssertEqual(pinned.count, 1)
        try await repo.delete(item.id)
        let deleted = try await repo.search("docker")
        XCTAssertTrue(deleted.isEmpty)
    }
    func testTwentyClipLimitIncludesPinsAndMixedTypesAndDeletesOldAssets() async throws {
        let (repo, storage) = try setupStore()
        let oldImage = ClipboardItem(type: .image, plainText: "old screenshot", hash: "old-image", now: Date(timeIntervalSince1970: 1))
        try await repo.save(oldImage, imageData: Data([1, 2, 3]))
        try await repo.togglePin(oldImage.id)
        for index in 2...25 {
            let item = ClipboardItem(type: index.isMultiple(of: 2) ? .image : .text,
                plainText: "clip \(index)", hash: "hash-\(index)", now: Date(timeIntervalSince1970: Double(index)))
            try await repo.save(item, imageData: item.type == .image ? Data([UInt8(index)]) : nil)
            let count = try await repo.count()
            XCTAssertLessThanOrEqual(count, 20, "The limit must hold immediately after each save")
        }
        let result = try await repo.search()
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.first?.plainText, "clip 25")
        XCTAssertEqual(result.last?.plainText, "clip 6")
        XCTAssertFalse(result.contains { $0.id == oldImage.id }, "Pins share the same total budget")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.assetURL("old-image.png")!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.assetURL("hash-2.png")!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.assetURL("hash-24.png")!.path))
        let expiredSearch = try await repo.search("old screenshot")
        XCTAssertTrue(expiredSearch.isEmpty)
    }
    func testRecopyAtCapacityRefreshesOldestWithoutEvictingAnotherClip() async throws {
        let (repo, _) = try setupStore()
        for index in 0..<20 { try await repo.save(clip("item \(index)", now: Date(timeIntervalSince1970: Double(index)))) }
        try await repo.save(clip("item 0", now: Date(timeIntervalSince1970: 50)))
        var result = try await repo.search()
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.first?.plainText, "item 0")
        try await repo.save(clip("newest", now: Date(timeIntervalSince1970: 51)))
        result = try await repo.search()
        XCTAssertEqual(result.count, 20)
        XCTAssertFalse(result.contains { $0.plainText == "item 1" })
        XCTAssertTrue(result.contains { $0.plainText == "item 0" })
    }
    func testExistingOversizedHistoryIsTrimmedWhenOpened() async throws {
        let (_, storage) = try setupStore()
        let database = try DatabaseQueue(path: storage.root.appendingPathComponent("clips.db").path)
        try await database.write { db in
            for index in 0..<35 {
                var item = clip("legacy \(index)", now: Date(timeIntervalSince1970: Double(index)))
                item.isFavorite = true
                try item.insert(db)
            }
        }
        let reopened = try ClipboardRepository(storage: storage)
        let result = try await reopened.search()
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.last?.plainText, "legacy 15")
    }
    func testEqualTimestampsEvictFirstInserted() async throws {
        let (repo, _) = try setupStore()
        for index in 0..<21 { try await repo.save(clip("tie \(index)", now: Date(timeIntervalSince1970: 100))) }
        let result = try await repo.search()
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.first?.plainText, "tie 20")
        XCTAssertFalse(result.contains { $0.plainText == "tie 0" })
    }
    func testClearDeletesAssetsButKeepsPinnedImages() async throws {
        let (repo, storage) = try setupStore()
        let first = ClipboardItem(type: .image, plainText: "first", hash: "first")
        let pin = ClipboardItem(type: .image, plainText: "pinned", hash: "pinned")
        try await repo.save(first, imageData: Data([1, 2, 3]))
        try await repo.save(pin, imageData: Data([4, 5, 6])); try await repo.togglePin(pin.id)
        try await repo.clear()
        let remaining = try await repo.count()
        XCTAssertEqual(remaining, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.assetURL("first.png")!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.assetURL("pinned.png")!.path))
        try await repo.clear(includePinned: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.assetURL("pinned.png")!.path))
    }
    func testPersistenceAndRichPayload() async throws {
        let (repo, storage) = try setupStore()
        let item = ClipboardItem(type: .richText, plainText: "hello", hash: "rich", html: Data("<b>hello</b>".utf8), rtf: Data([1, 2]))
        try await repo.save(item)
        let reopened = try ClipboardRepository(storage: storage)
        let result = try await reopened.search("hello")
        XCTAssertEqual(result.first?.html, item.html)
        XCTAssertEqual(result.first?.rtf, item.rtf)
    }
    func testTypeFiltersAndPagination() async throws {
        let (repo, _) = try setupStore()
        for index in 0..<7 { try await repo.save(clip("clip \(index)", now: Date(timeIntervalSince1970: Double(index)))) }
        let first = try await repo.search(limit: 3)
        let next = try await repo.search(limit: 3, offset: 3)
        XCTAssertEqual(first.count, 3); XCTAssertEqual(next.count, 3)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: next.map(\.id)))
        let images = try await repo.search(filter: .images)
        XCTAssertTrue(images.isEmpty)
        for kind in [ClipKind.image, .link, .file] {
            try await repo.save(ClipboardItem(type: kind, plainText: kind.label, hash: kind.rawValue))
        }
        let onlyImages = try await repo.search(filter: .images)
        let onlyLinks = try await repo.search(filter: .links)
        let onlyFiles = try await repo.search(filter: .files)
        XCTAssertEqual(onlyImages.map(\.type), [.image])
        XCTAssertEqual(onlyLinks.map(\.type), [.link])
        XCTAssertEqual(onlyFiles.map(\.type), [.file])
    }
    func testAssetPathCannotEscapeStorage() throws {
        let (_, storage) = try setupStore()
        XCTAssertNil(storage.assetURL("../clips.db"))
        XCTAssertNil(storage.assetURL("/tmp/secret"))
        XCTAssertNil(storage.assetURL(".."))
    }
}
