import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Parley

/// Animated custom emoji in message text and reaction pills: the drawing picks the frame showing at the time.
@MainActor struct AnimatedEmojiTests {
    @Test func theFrameFollowsTheClockAndLoops() {
        let durations = [0.1, 0.2, 0.1]   // a 0.4 s loop
        #expect([0.0, 0.05, 0.1, 0.29, 0.31, 0.39, 0.4, 0.45].map { NSImage.frame(durations: durations, at: $0) } == [0, 0, 1, 1, 2, 2, 0, 0])
        #expect(NSImage.frame(durations: [], at: 3) == 0)
    }
    /// As browsers play GIFs: a frame of under 20 ms (often 0, meaning "as fast as possible") shows for 100 ms.
    @Test func tooShortFramesShowForATenthOfASecond() {
        #expect(NSImage.playable([0, 0.01, 0.02, 0.5]) == [0.1, 0.1, 0.02, 0.5])
    }
    @Test func drawingAnAnimatedGIFDrawsTheFrameForTheTime() throws {
        let image = try #require(NSImage(data: Self.gif([.red, .green, .blue], delay: 0.1)))
        #expect(image.animated)
        func color(at time: TimeInterval) -> NSColor? {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.drawFrame(in: NSRect(x: 0, y: 0, width: 4, height: 4), at: time)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: 2, y: 2)
        }
        #expect((color(at: 0.05)?.redComponent ?? 0) > 0.9)
        #expect((color(at: 0.15)?.greenComponent ?? 0) > 0.9)
        #expect((color(at: 0.25)?.blueComponent ?? 0) > 0.9)
    }
    static func gif(_ colors: [NSColor], delay: Double) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, colors.count, nil)!
        for color in colors {
            let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
