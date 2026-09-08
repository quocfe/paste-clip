import XCTest
import AppKit
import Darwin
@testable import ClipStackCore

final class ScreenshotTests: XCTestCase {
    @MainActor
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<4 {
            pixels[index * 4] = 0; pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = 255; pixels[index * 4 + 3] = 255
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    private func markScreenshot(_ url: URL) throws {
        let flag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let status = flag.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, flag.count, 0, 0)
        }
        XCTAssertEqual(status, 0)
    }
    @MainActor
    func testNewScreenshotImportsOnceAndIgnoresOldAndOrdinaryImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.png")
        try png().write(to: old); try markScreenshot(old)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-60)], ofItemAtPath: old.path)
        let watcher = ScreenshotWatcher(directories: { [root] })
        var captures: [CapturedClip] = []
        watcher.onCapture = { captures.append($0) }
        let ordinary = root.appendingPathComponent("ordinary.png")
        try png().write(to: ordinary)
        let screenshot = root.appendingPathComponent("localized-screenshot-name.png")
        try png().write(to: screenshot); try markScreenshot(screenshot)
        watcher.poll(); watcher.poll()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.item.type, .image)
        XCTAssertEqual(captures.first?.item.sourceAppName, "Screenshot")
        XCTAssertNotNil(captures.first?.imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path), "Original screenshots must remain untouched")
    }
    @MainActor
    func testScreenshotPauseAndPartialFileRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = ScreenshotWatcher(directories: { [root] })
        var count = 0
        watcher.onCapture = { _ in count += 1 }
        watcher.paused = true
        let paused = root.appendingPathComponent("paused.png")
        try png().write(to: paused); try markScreenshot(paused)
        watcher.poll()
        watcher.paused = false
        watcher.poll()
        XCTAssertEqual(count, 0)
        let partial = root.appendingPathComponent("writing.png")
        try Data([1, 2, 3]).write(to: partial); try markScreenshot(partial)
        watcher.poll()
        XCTAssertEqual(count, 0)
        try png().write(to: partial)
        watcher.poll(); watcher.poll()
        XCTAssertEqual(count, 1)
    }
    @MainActor
    func testScreenshotAndClipboardImageShareHashAndDoNotOverwriteClipboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("screenshot.png")
        let data = try png(); try data.write(to: url)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(data, forType: .png)
        let clipboard = try XCTUnwrap(ClipboardParser.parse(board, sourceID: nil, sourceName: "Test", excludedApps: [], filterSecrets: false))
        let count = board.changeCount
        let screenshot = try XCTUnwrap(ScreenshotWatcher.readScreenshot(url, capturedAt: Date()))
        XCTAssertEqual(screenshot.item.contentHash, clipboard.item.contentHash)
        XCTAssertEqual(board.changeCount, count)
    }
}
