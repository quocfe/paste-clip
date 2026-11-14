import AppKit
import XCTest

@testable import ClipStackCore

final class ClipboardTests: XCTestCase {
    @MainActor private func parse(_ board: NSPasteboard, filter: Bool = true, source: String = "com.apple.Terminal")
        -> CapturedClip?
    {
        ClipboardParser.parse(
            board, sourceID: source, sourceName: "Terminal", excludedApps: PrivacyFilter.defaultExcludedApps,
            filterSecrets: filter)
    }
    @MainActor
    func testPrivateMarkersAndExcludedApplications() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hello", forType: .string)
        XCTAssertNil(parse(board, source: "com.bitwarden.desktop"))
        board.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertNil(parse(board, filter: false))
    }
    @MainActor
    func testTextURLAndRichTextRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageService(root: root)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("https://github.com/quocfe/clipstack", forType: .string)
        XCTAssertEqual(parse(board)?.item.type, .link)
        board.clearContents()
        board.setString("hello world", forType: .string)
        board.setData(Data("<b>hello world</b>".utf8), forType: .html)
        let captured = try XCTUnwrap(parse(board))
        XCTAssertEqual(captured.item.type, .richText)
        try ClipboardWriter.write(captured.item, storage: storage, to: board)
        XCTAssertEqual(board.string(forType: .string), "hello world")
        XCTAssertEqual(board.data(forType: .html), captured.item.html)
        XCTAssertNil(parse(board), "Restoring a clip must not record it again")
    }
    @MainActor
    func testMultipleFilesRoundTripAndMissingFileFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try StorageService(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appendingPathComponent("one.txt"), root.appendingPathComponent("two.txt")]
        for url in urls { try Data("test".utf8).write(to: url) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects(urls.map { $0 as NSURL })
        let captured = try XCTUnwrap(parse(board))
        XCTAssertEqual(captured.item.type, .file)
        XCTAssertEqual(captured.item.files.count, 2)
        try ClipboardWriter.write(captured.item, storage: storage, to: board)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        try FileManager.default.removeItem(at: urls[0])
        XCTAssertThrowsError(try ClipboardWriter.write(captured.item, storage: storage, to: board))
    }
    @MainActor
    func testImageCapture() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 8, bitsPerPixel: 32))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        board.setData(png, forType: .png)
        let captured = try XCTUnwrap(parse(board))
        XCTAssertEqual(captured.item.type, .image)
        XCTAssertNotNil(captured.imageData)
    }
    @MainActor
    func testWatcherPauseDoesNotBackfill() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let watcher = ClipboardWatcher(board: board)
        var count = 0
        watcher.onChange = { _ in count += 1 }
        board.clearContents()
        board.setString("first", forType: .string)
        watcher.poll()
        watcher.poll()
        XCTAssertEqual(count, 1)
        watcher.paused = true
        board.clearContents()
        board.setString("private", forType: .string)
        watcher.poll()
        watcher.paused = false
        watcher.poll()
        XCTAssertEqual(count, 1)
        board.clearContents()
        board.setString("next", forType: .string)
        watcher.poll()
        XCTAssertEqual(count, 2)
    }
    @MainActor
    private func tinyPNG() throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    @MainActor
    func testTextWithRenderedPictureIsCapturedAsText() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        // Spreadsheet and word-processor apps attach a picture of the copied text.
        board.declareTypes([.string, .rtf, .png], owner: nil)
        board.setString("Q3 revenue", forType: .string)
        board.setData(Data(#"{\rtf1 Q3 revenue}"#.utf8), forType: .rtf)
        board.setData(try tinyPNG(), forType: .png)
        let captured = try XCTUnwrap(parse(board))
        XCTAssertEqual(captured.item.type, .richText)
        XCTAssertEqual(captured.item.plainText, "Q3 revenue")
        XCTAssertNil(captured.imageData)

        // A picture copied with only a caption or address and no RTF stays an image.
        board.clearContents()
        board.declareTypes([.string, .png], owner: nil)
        board.setString("https://example.com/picture.png", forType: .string)
        board.setData(try tinyPNG(), forType: .png)
        XCTAssertEqual(parse(board)?.item.type, .image)
    }
    @MainActor
    func testReadDefersImageDecodingAndReportsSkipReasons() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        func read(source: String = "com.apple.Terminal", filter: Bool = true) -> ClipboardReading {
            ClipboardParser.read(
                board, sourceID: source, sourceName: "Terminal",
                excludedApps: PrivacyFilter.defaultExcludedApps, filterSecrets: filter)
        }
        board.setData(try tinyPNG(), forType: .png)
        guard case .image(let pending) = read() else { return XCTFail("Images must be deferred, not decoded") }
        let clip = try XCTUnwrap(ImageNormalizer.clip(from: pending))
        XCTAssertEqual(clip.item.type, .image)
        XCTAssertEqual(clip.item.updatedAt, pending.capturedAt)

        board.clearContents()
        board.setString("123456", forType: .string)
        guard case .skipped(.likelySecret) = read() else { return XCTFail("Expected a secret skip") }
        guard case .clip = read(filter: false) else { return XCTFail("Filter off must record the text") }
        guard case .skipped(.excludedApp) = read(source: "com.bitwarden.desktop") else {
            return XCTFail("Expected an excluded-app skip")
        }
        board.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        guard case .skipped(.privateContent) = read(filter: false) else {
            return XCTFail("Expected a private-content skip")
        }
        XCTAssertNil(
            ImageNormalizer.clip(from: Data([1, 2, 3]), sourceID: nil, sourceName: "Test", capturedAt: Date()))
    }
    func testSensitiveFilterAndRepresentationHashes() {
        for secret in [
            "123456", "password=hidden", "AKIA1234567890123456", "-----BEGIN PRIVATE KEY-----",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature",
        ] {
            XCTAssertTrue(PrivacyFilter.looksSensitive(secret))
        }
        XCTAssertFalse(PrivacyFilter.looksSensitive("docker compose up -d"))
        XCTAssertNotEqual(
            ContentHash.make(kind: .text, parts: [Data("ab".utf8), Data("c".utf8)]),
            ContentHash.make(kind: .text, parts: [Data("a".utf8), Data("bc".utf8)]))
    }
}
