import AppKit
import ClipStackCore
import XCTest

@testable import ClipStack

/// App-layer pieces that can run without launching the app, the global pasteboard, or a hotkey.
final class AppLayerTests: XCTestCase {
    @MainActor
    func testSettingsDefaultsAndPersistence() throws {
        let suite = "ClipStackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.filterSecrets)
        XCTAssertTrue(settings.importScreenshots)
        XCTAssertFalse(settings.paused)
        XCTAssertEqual(settings.excludedApps, PrivacyFilter.defaultExcludedApps)
        XCTAssertEqual(settings.shortcutLabel, "⌘ ⇧ V")

        settings.importScreenshots = false
        settings.paused = true
        settings.shortcutOption = true
        settings.excludedApps.append("com.example.app")

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.importScreenshots)
        XCTAssertTrue(reloaded.paused)
        XCTAssertEqual(reloaded.shortcutLabel, "⌘ ⌥ V")
        XCTAssertTrue(reloaded.excludedApps.contains("com.example.app"))
    }

    @MainActor
    func testThumbnailCacheDownsamplesAndReusesImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1200, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 9600, bitsPerPixel: 32))
        let url = root.appendingPathComponent("large.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)

        let cache = ThumbnailCache()
        XCTAssertNil(cache.cached(url))
        let loaded = await cache.image(for: url)
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.size.width, CGFloat(ThumbnailCache.maxPixelSize))
        XCTAssertEqual(image.size.height, CGFloat(ThumbnailCache.maxPixelSize / 2))
        XCTAssertTrue(cache.cached(url) === image)
        XCTAssertTrue(cache.load(url) === image)

        let missing = await cache.image(for: root.appendingPathComponent("missing.png"))
        XCTAssertNil(missing)
    }
}
