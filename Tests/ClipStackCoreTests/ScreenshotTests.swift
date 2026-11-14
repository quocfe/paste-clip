import AppKit
import Darwin
import XCTest

@testable import ClipStackCore

final class ScreenshotTests: XCTestCase {
    @MainActor
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<4 {
            pixels[index * 4] = 0
            pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = 255
            pixels[index * 4 + 3] = 255
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
    func testNewScreenshotImportsOnceAndIgnoresOldAndOrdinaryImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.png")
        try png().write(to: old)
        try markScreenshot(old)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-60)], ofItemAtPath: old.path)
        let watcher = ScreenshotWatcher(directories: { [root] })
        var captures: [CapturedClip] = []
        watcher.onCapture = { captures.append($0) }
        let ordinary = root.appendingPathComponent("ordinary.png")
        try png().write(to: ordinary)
        let screenshot = root.appendingPathComponent("localized-screenshot-name.png")
        try png().write(to: screenshot)
        try markScreenshot(screenshot)
        await watcher.poll()
        await watcher.poll()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.item.type, .image)
        XCTAssertEqual(captures.first?.item.sourceAppName, "Screenshot")
        XCTAssertNotNil(captures.first?.imageData)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: screenshot.path), "Original screenshots must remain untouched")
    }
    @MainActor
    func testScreenshotPauseAndPartialFileRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = ScreenshotWatcher(directories: { [root] })
        var count = 0
        watcher.onCapture = { _ in count += 1 }
        watcher.paused = true
        let paused = root.appendingPathComponent("paused.png")
        try png().write(to: paused)
        try markScreenshot(paused)
        await watcher.poll()
        watcher.paused = false
        await watcher.poll()
        XCTAssertEqual(count, 0)
        let partial = root.appendingPathComponent("writing.png")
        try Data([1, 2, 3]).write(to: partial)
        try markScreenshot(partial)
        await watcher.poll()
        XCTAssertEqual(count, 0)
        try png().write(to: partial)
        await watcher.poll()
        await watcher.poll()
        XCTAssertEqual(count, 1)
    }
    @MainActor
    func testPendingScreenshotImportsBeforeItReachesItsDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pending = root.appendingPathComponent("NSIRD_screencaptureui_test", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        for directory in [pending, desktop] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = ScreenshotWatcher(directories: { [desktop] }, pendingDirectories: { [pending] })
        var captures: [CapturedClip] = []
        watcher.onCapture = { captures.append($0) }

        // macOS holds the file here while the floating thumbnail is visible.
        let held = pending.appendingPathComponent("Screenshot.png")
        try png().write(to: held)
        await watcher.poll()
        XCTAssertEqual(captures.count, 0, "A file that may still be written must wait for the next poll")
        // Backdating the file would also move its creation date before the watcher started.
        try await Task.sleep(nanoseconds: 300_000_000)
        await watcher.poll()
        await watcher.poll()
        XCTAssertEqual(captures.count, 1)

        // The later move to the destination yields the same content hash, so the repository
        // refreshes the existing clip instead of adding a second one.
        let final = desktop.appendingPathComponent("Screenshot.png")
        try FileManager.default.moveItem(at: held, to: final)
        try markScreenshot(final)
        await watcher.poll()
        XCTAssertEqual(captures.count, 2)
        XCTAssertEqual(captures[0].item.contentHash, captures[1].item.contentHash)
    }
    @MainActor
    func testScreenshotAndClipboardImageShareHashAndDoNotOverwriteClipboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("screenshot.png")
        let data = try png()
        try data.write(to: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(data, forType: .png)
        let clipboard = try XCTUnwrap(
            ClipboardParser.parse(board, sourceID: nil, sourceName: "Test", excludedApps: [], filterSecrets: false))
        let count = board.changeCount
        let screenshot = try XCTUnwrap(ScreenshotWatcher.readScreenshot(url, capturedAt: Date()))
        XCTAssertEqual(screenshot.item.contentHash, clipboard.item.contentHash)
        XCTAssertEqual(board.changeCount, count)
    }
}
