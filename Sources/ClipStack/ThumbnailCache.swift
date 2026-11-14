import AppKit
import ImageIO

/// Downsampled previews for image cards. Assets are named by content hash, so a URL always
/// maps to the same pixels and entries never go stale.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Cards show images at roughly 230 × 164 pt; this covers 2x displays with headroom.
    nonisolated static let maxPixelSize = 600
    private let cache = NSCache<NSURL, NSImage>()

    init() { cache.countLimit = 64 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// Decodes on the calling thread. Used by rendering tests and as the primitive for `image`.
    @discardableResult
    func load(_ url: URL) -> NSImage? {
        if let image = cached(url) { return image }
        guard let thumbnail = Self.downsample(url) else { return nil }
        return store(thumbnail, for: url)
    }

    /// Decodes away from the main actor so scrolling and selection stay responsive.
    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        let thumbnail = await Task.detached(priority: .userInitiated) { Self.downsample(url) }.value
        guard let thumbnail else { return nil }
        return cached(url) ?? store(thumbnail, for: url)
    }

    private func store(_ thumbnail: CGImage, for url: URL) -> NSImage {
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    nonisolated static func downsample(_ url: URL, maxPixelSize: Int = ThumbnailCache.maxPixelSize) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
