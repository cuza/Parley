import AppKit
import ParleyDomain
import SwiftUI

/// A small animation (a custom emoji) decoded whole off the main thread, at the size it shows, and attached to its
/// NSImage: every frame is ready to draw, so scrolling past hundreds of them decodes nothing on the main thread. Drawn
/// as an image, the NSImage is the first frame; `NSImage.drawFrame` and `AnimatedImage` play the rest.
final class AnimationFrames: NSObject {
    /// Animations up to this many pixels a side are decoded whole; bigger ones (GIFs, media) play through NSImageView,
    /// which decodes a frame at a time.
    nonisolated static let maxPixels = 256
    let frames: [NSBitmapImageRep], durations: [TimeInterval]
    nonisolated private init(frames: [NSBitmapImageRep], durations: [TimeInterval]) {
        self.frames = frames
        self.durations = durations
    }
    nonisolated(unsafe) fileprivate static let key = UnsafeRawPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    nonisolated static func image(_ source: CGImageSource, maxPixels: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        var frames: [NSBitmapImageRep] = []
        var durations: [TimeInterval] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                return nil
            }
            frames.append(NSBitmapImageRep(cgImage: frame))
            durations.append(ImageCache.delay(source, index))
        }
        guard let first = frames.first else { return nil }
        let image = NSImage(size: NSSize(width: first.pixelsWide, height: first.pixelsHigh))
        image.addRepresentation(first)
        objc_setAssociatedObject(
            image, key, AnimationFrames(frames: frames, durations: NSImage.playable(durations)),
            .OBJC_ASSOCIATION_RETAIN)
        return image
    }
}
extension NSImage {
    /// Set on a small animation `ImageCache` decoded whole (`AnimationFrames`).
    nonisolated var decodedFrames: AnimationFrames? {
        objc_getAssociatedObject(self, AnimationFrames.key) as? AnimationFrames
    }
}

/// Plays an animated picture: a small one from its decoded frames (`AnimationFrames`) on a display link, a GIF with NSImageView.
/// SwiftUI's Image shows only the first frame.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> AnimatedPictureView { AnimatedPictureView() }
    func updateNSView(_ view: AnimatedPictureView, context: Context) { view.image = image }
}
final class AnimatedPictureView: NSView {
    private let gif = NSImageView(), frames = CALayer()
    var image: NSImage? { didSet { if image !== oldValue { show() } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        frames.contentsGravity = .resizeAspect
        layer?.addSublayer(frames)
        gif.imageScaling = .scaleProportionallyUpOrDown
        gif.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        gif.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gif.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(gif)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        gif.frame = bounds
        CATransaction.withoutAnimation { frames.frame = bounds }
    }
    /// Decoded frames play as a Core Animation keyframe animation, which the render server runs with no work on the main
    /// thread, in step with every other copy (the same clock as `NSImage.drawFrame`).
    private func show() {
        frames.removeAnimation(forKey: "frames")
        guard let decoded = image?.decodedFrames else {
            frames.contents = nil
            gif.image = image
            gif.isHidden = false
            return
        }
        gif.image = nil
        gif.isHidden = true
        let pictures = decoded.frames.compactMap(\.cgImage)
        frames.contents = pictures.first
        let loop = decoded.durations.reduce(0, +)
        guard pictures.count == decoded.durations.count, pictures.count > 1, loop > 0,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = pictures
        var start = 0.0
        var keyTimes: [NSNumber] = []
        for duration in decoded.durations {
            keyTimes.append(NSNumber(value: start / loop))
            start += duration
        }
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = loop
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        let phase = Date.now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
        animation.beginTime = frames.convertTime(CACurrentMediaTime(), from: nil) - phase
        frames.add(animation, forKey: "frames")
    }
}

extension NSImage {
    /// More than one frame: a GIF (or animated PNG) that moves.
    var animated: Bool { decodedFrames != nil || animatedRep != nil }
    private var animatedRep: NSBitmapImageRep? {
        representations.lazy.compactMap { $0 as? NSBitmapImageRep }.first {
            ($0.value(forProperty: .frameCount) as? Int ?? 1) > 1
        }
    }
    /// Draws the frame showing at `time` (seconds on a shared clock, so every copy of an emoji moves together), or the
    /// first one with Reduce Motion on. For pictures drawn inside text (custom emoji in a message or a reaction pill),
    /// which NSImageView can't animate; the view redraws while one shows.
    @MainActor func drawFrame(in rect: NSRect, at time: TimeInterval = Date.now.timeIntervalSinceReferenceDate) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let decoded = decodedFrames {
            decoded.frames[still ? 0 : Self.frame(durations: decoded.durations, at: time)].draw(in: rect)
            return
        }
        guard let rep = animatedRep else {
            draw(in: rect)
            return
        }
        let frames = Self.frames(rep)
        frames.images[still ? 0 : Self.frame(durations: frames.durations, at: time)].draw(in: rect)
    }
    /// Redraws a second that show every frame, as NSImageView plays it: one per shortest frame, up to 60. Nil when still.
    @MainActor var frameRate: Float? {
        let durations = decodedFrames?.durations ?? animatedRep.map { Self.frames($0).durations }
        guard let shortest = durations?.min(), shortest > 0 else { return nil }
        return Float(min(60, (1 / shortest).rounded()))
    }
    /// Which frame shows `time` seconds into a loop of these durations.
    nonisolated static func frame(durations: [TimeInterval], at time: TimeInterval) -> Int {
        let loop = durations.reduce(0, +)
        guard loop > 0 else { return 0 }
        var left = time.truncatingRemainder(dividingBy: loop)
        for (index, duration) in durations.enumerated() {
            if left < duration { return index }
            left -= duration
        }
        return durations.count - 1
    }
    /// As browsers play GIFs: a frame of 10 ms or less (often 0, "as fast as possible") shows for 100 ms. The cutoff sits
    /// between 10 and 20 ms because AppKit reports frame times as floats, a 20 ms frame as 0.0199999995.
    nonisolated static func playable(_ durations: [TimeInterval]) -> [TimeInterval] {
        durations.map { $0 < 0.015 ? 0.1 : $0 }
    }
    /// An animation's frames, decoded once in order: a GIF frame drawn on its own is rebuilt from every frame before it,
    /// which costs milliseconds each time a redraw jumps ahead.
    private final class Frames {
        let images: [NSBitmapImageRep], durations: [TimeInterval]
        init(images: [NSBitmapImageRep], durations: [TimeInterval]) {
            self.images = images
            self.durations = durations
        }
    }
    // ponytail: every frame stays decoded while its picture is in `ImageCache` (74 frames of 128 px are about 5 MB);
    // decode at the drawn size if many animated emoji show at once.
    @MainActor private static let decoded = NSMapTable<NSBitmapImageRep, Frames>.weakToStrongObjects()
    @MainActor private static func frames(_ rep: NSBitmapImageRep) -> Frames {
        if let known = decoded.object(forKey: rep) { return known }
        let count = rep.value(forProperty: .frameCount) as? Int ?? 1
        var images: [NSBitmapImageRep] = []
        var durations: [TimeInterval] = []
        for frame in 0..<count {
            rep.setProperty(.currentFrame, withValue: frame)
            durations.append((rep.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1)
            guard let image = rep.cgImage, let still = Self.decodedCopy(image) else { continue }
            images.append(NSBitmapImageRep(cgImage: still))
        }
        rep.setProperty(.currentFrame, withValue: 0)
        let frames =
            images.count == count
            ? Frames(images: images, durations: playable(durations)) : Frames(images: [rep], durations: [1])
        decoded.setObject(frames, forKey: rep)
        return frames
    }
    /// The frame's pixels drawn into a bitmap of their own, so drawing it later decodes nothing.
    private static func decodedCopy(_ image: CGImage) -> CGImage? {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context?.makeImage()
    }
}

/// Redraws a view while it shows an animated custom emoji, at the emoji's own pace (`NSImage.frameRate`), with the view's
/// display link: it follows the screen, keeps going while a list scrolls, and stops when the view leaves its window.
/// Nothing plays with Reduce Motion on.
@MainActor final class EmojiAnimation: NSObject {
    private weak var view: NSView?
    private let redraw: () -> Void
    private var link: CADisplayLink?
    var playing: Bool { link != nil }
    init(_ view: NSView, redraw: @escaping () -> Void) {
        self.view = view
        self.redraw = redraw
    }
    /// Plays while one of `pictures` is an animated picture `ImageCache` has.
    func update(_ pictures: Set<Attachment>) {
        play(at: pictures.compactMap { ImageCache.cached($0)?.frameRate }.max())
    }
    /// Redraws `rate` times a second; nil stops.
    func play(at rate: Float?) {
        guard let rate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let view else {
            stop()
            return
        }
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 10), maximum: rate, preferred: rate)
    }
    func stop() {
        link?.invalidate()
        link = nil
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard let view else {
            stop()
            return
        }
        if view.window != nil { redraw() }
    }
}
