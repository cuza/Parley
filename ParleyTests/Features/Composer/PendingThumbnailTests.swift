import AppKit
import Testing

@testable import Parley

/// A picture waiting in the composer shows as a small thumbnail made once, off the main thread: typing doesn't read it.
@MainActor struct PendingThumbnailTests {
    @Test func aLargePictureBecomesASmallThumbnail() async throws {
        let big = NSImage(size: NSSize(width: 3000, height: 2000), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(big.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let file = URL.temporaryDirectory.appending(path: "parley-pending-\(UUID().uuidString).png")
        try png.write(to: file)
        let thumbnail = try #require(await PendingThumbnail.load(file))
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 64)
    }
}

/// Image caches count what pictures take in memory, so many large ones can't pile up under a count limit.
@MainActor struct ImageCacheCostTests {
    @Test func aPicturesCostIsItsPixels() {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 50, height: 25))
        image.addRepresentation(rep)
        #expect(image.pixelBytes == 100 * 50 * 4)
        #expect(ImageCache.shared.totalCostLimit > 0)
    }
}
