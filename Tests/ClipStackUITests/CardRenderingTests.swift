import AppKit
import ClipStackCore
import SwiftUI
import XCTest

@testable import ClipStack

/// Render production card views with synthetic test data only. No AppState, app launch,
/// global pasteboard, screen capture, screenshot watcher, or global hotkey is created.
final class CardRenderingTests: XCTestCase {
    @MainActor
    func testRenderTextAndImageCardsInLightAndDarkAppearance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try StorageService(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 640, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<100 {
            for x in 0..<160 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = UInt8(x * 255 / 160)
                pixels[offset + 1] = 115
                pixels[offset + 2] = UInt8(y * 255 / 100)
                pixels[offset + 3] = 255
            }
        }
        let imageName = try storage.storeImage(
            XCTUnwrap(bitmap.representation(using: .png, properties: [:])), hash: "render-fixture")
        // Cards never decode assets while rendering; a synchronous render needs a warm cache.
        XCTAssertNotNil(ThumbnailCache.shared.load(try XCTUnwrap(storage.assetURL(imageName))))
        let now = Date(timeIntervalSince1970: 1_788_878_580)
        let clips = [
            ClipboardItem(
                type: .text, plainText: "Copy once.\nKeep your flow.", hash: "short", sourceName: "Notes", now: now),
            ClipboardItem(
                type: .image, plainText: "Image · 160 × 100", hash: "image", sourceName: "Screenshot",
                assetPath: imageName, now: now),
            ClipboardItem(
                type: .text,
                plainText:
                    "Lưu tối đa 20 mục, gồm cả text và ảnh. Khi có mục mới, ClipStack tự động xóa mục cũ nhất.\n\nẢnh chụp màn hình mới sẽ xuất hiện ở đây.",
                hash: "long", sourceName: "TextEdit", now: now),
            ClipboardItem(
                type: .link, plainText: "https://example.com/design/clipboard", hash: "link", sourceName: "Safari",
                now: now),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = HStack(spacing: 14) {
                ForEach(clips) { item in
                    ClipCard(item: item, storage: storage, selected: item.id == clips[0].id)
                }
            }
            .padding(22)
            .background(scheme == .light ? Color(white: 0.92) : Color(white: 0.15))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let representation = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertEqual(image.size.width, 1006, accuracy: 1)
            XCTAssertEqual(image.size.height, 288, accuracy: 1)
            // A blank image card still has the correct size: verify the preview's pixels too.
            let left = try XCTUnwrap(representation.colorAt(x: 580, y: 288)?.usingColorSpace(.sRGB))
            let right = try XCTUnwrap(representation.colorAt(x: 948, y: 288)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(right.redComponent - left.redComponent, 0.5)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10000)
            if let directory = ProcessInfo.processInfo.environment["CLIPSTACK_PREVIEW_OUTPUT"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("cards-\(scheme == .light ? "light" : "dark").png"))
            }
        }
    }
}
