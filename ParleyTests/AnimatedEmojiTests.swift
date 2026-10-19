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
    /// Google serves animated custom emoji as WebP, which NSImage splits into separate pictures with no frame count: the
    /// decoder rebuilds it as a GIF, so it plays like one, with each frame for its time.
    @Test func anAnimatedWebPDecodesToAPlayableAnimation() throws {
        let webp = try #require(Data(base64Encoded: Self.webp))   // three 8×8 frames, red, green, blue, 100 ms each (img2webp)
        #expect(NSImage(data: webp)?.animated == false)   // what AppKit makes of it alone
        let image = try #require(ImageCache.decode(webp, maxPixels: 64))
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
    /// Redraws come at the emoji's own pace, as NSImageView plays it: one per frame of its shortest frame, up to 60 a second.
    @Test func theFrameRateFollowsTheShortestFrame() throws {
        #expect(try #require(NSImage(data: Self.gif([.red, .green], delay: 0.04))).frameRate == 25)
        #expect(try #require(NSImage(data: Self.gif([.red, .green], delay: 0.01))).frameRate == 10)   // played as 0.1 s
        #expect(NSImage(size: NSSize(width: 4, height: 4)).frameRate == nil)
    }
    /// Frames are decoded once, in order: a later redraw that jumps frames ahead draws a decoded copy instead of seeking
    /// the GIF, which rebuilds every frame in between (milliseconds per emoji per redraw).
    @Test func framesAreDecodedOnce() throws {
        let image = try #require(NSImage(data: Self.gif([.red, .green, .blue, .red, .green, .blue], delay: 0.1)))
        let gif = try #require(image.representations.first as? NSBitmapImageRep)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.drawFrame(in: NSRect(x: 0, y: 0, width: 4, height: 4), at: 0)
        gif.setProperty(.currentFrame, withValue: 5)
        image.drawFrame(in: NSRect(x: 0, y: 0, width: 4, height: 4), at: 0.25)   // frame 2
        #expect(gif.value(forProperty: .currentFrame) as? Int == 5)
        #expect((bitmap.colorAt(x: 2, y: 2)?.blueComponent ?? 0) > 0.9)
    }
    /// A view showing an animated emoji redraws while it shows one, and stops once none is left or none moves.
    @Test func anAnimationPlaysOnlyWhileAnAnimatedEmojiShows() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let animated = try #require(CustomEmoji(id: "a", shortcode: "a", imageURL: URL(string: "https://example.invalid/animated-\(UUID())")).image)
        let still = try #require(CustomEmoji(id: "s", shortcode: "s", imageURL: URL(string: "https://example.invalid/still-\(UUID())")).image)
        ImageCache.shared.setObject(try #require(NSImage(data: Self.gif([.red, .green], delay: 0.04))), forKey: ImageCache.key(animated) as NSString)
        ImageCache.shared.setObject(NSImage(size: NSSize(width: 4, height: 4)), forKey: ImageCache.key(still) as NSString)
        let animation = EmojiAnimation(view) {}
        animation.update([still])
        #expect(!animation.playing)
        animation.update([still, animated])
        #expect(animation.playing)
        animation.update([])
        #expect(!animation.playing)
    }
    /// The composer plays an animated emoji as a message does, instead of moving a frame at each keypress.
    @Test func theComposerPlaysAnAnimatedEmoji() throws {
        let emoji = CustomEmoji(id: "a", shortcode: "dance", imageURL: URL(string: "https://example.invalid/composer-\(UUID())"))
        ImageCache.shared.setObject(try #require(NSImage(data: Self.gif([.red, .green], delay: 0.04))), forKey: ImageCache.key(try #require(emoji.image)) as NSString)
        let view = ComposerTextView(usingTextLayoutManager: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.insertCustomEmoji(emoji, replacing: view.selectedRange())
        #expect(view.animatesEmoji)
        view.selectAll(nil); view.deleteBackward(nil)
        #expect(!view.animatesEmoji)
    }
    static let webp = "UklGRrQAAABXRUJQVlA4WAoAAAACAAAABwAABwAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAAcAAAcAAGQAAAJWUDhMDwAAAC8HwAEABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAcAAAcAAGQAAABWUDhMDwAAAC8HwAEAB9D/iP4HIqL/AQBBTk1GKAAAAAAAAAAAAAcAAAcAAGQAAABWUDhMDwAAAC8HwAEABxDR//4HIqL/AQA="
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
