import AppKit
import Foundation

// Draw a native, resolution-independent icon; no downloaded assets or fonts.
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/ClipStack.iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 204, yRadius: 204)
        NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.98, alpha: 1),
                   ending: NSColor(calibratedRed: 0.30, green: 0.24, blue: 0.69, alpha: 1))!.draw(in: background, angle: -65)
        for index in 0..<3 {
            let offset = CGFloat(index) * 72
            let card = NSBezierPath(roundedRect: NSRect(x: 258 + offset * 0.35, y: 235 + offset, width: 440, height: 340), xRadius: 48, yRadius: 48)
            NSColor.white.withAlphaComponent(index == 2 ? 0.98 : 0.26).setFill(); card.fill()
        }
        NSColor(calibratedRed: 0.43, green: 0.35, blue: 0.86, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 375, y: 565, width: 255, height: 26), xRadius: 13, yRadius: 13).fill()
        NSBezierPath(roundedRect: NSRect(x: 375, y: 505, width: 170, height: 26), xRadius: 13, yRadius: 13).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/ClipStack.icns"]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("Icon generation failed") }
