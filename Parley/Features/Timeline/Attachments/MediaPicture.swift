import AppKit
import CoreImage
import SwiftUI

/// A picture, GIF or video poster filling its frame exactly: stretched by under 2% when its aspect is the frame's (the
/// frame is rounded to whole points), else aspect-fit and centred over a blurred, enlarged copy of itself (Telegram's
/// `blurBackground`), so a frame wider or taller than the picture shows no bare bubble; a veil of half the background's colour tones it down.
/// A GIF's blur is its first frame.
struct MediaPicture: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> MediaPictureView { MediaPictureView() }
    func updateNSView(_ view: MediaPictureView, context: Context) { view.image = image }
}

final class MediaPictureView: NSView {
    private let picture = NSImageView(), blur = CALayer(), veil = CALayer()
    /// Past this the picture is not taken for the frame's shape: it is fitted and the blur shows beside it.
    static let stretchTolerance: CGFloat = 0.02
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            picture.image = image
            blur.contents = image.flatMap(Self.blurred)
            needsLayout = true
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.contentsGravity = .resizeAspectFill
        blur.masksToBounds = true
        blur.magnificationFilter = .linear
        layer?.addSublayer(blur)
        blur.addSublayer(veil)  // Telegram's: half the background's colour over the blur, so it reads as fill, not picture
        picture.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(picture)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        CATransaction.withoutAnimation {
            blur.frame = bounds
            veil.frame = blur.bounds
            effectiveAppearance.performAsCurrentDrawingAppearance {
                veil.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
            }
        }
        guard let size = image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            picture.frame = bounds
            return
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        if bounds.width - fitted.width <= bounds.width * Self.stretchTolerance,
            bounds.height - fitted.height <= bounds.height * Self.stretchTolerance
        {
            picture.imageScaling = .scaleAxesIndependently
            picture.frame = bounds
            blur.isHidden = true
        } else {
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.frame = bounds
            blur.isHidden = false
        }
    }

    // ponytail: synchronous on first show; move it to the decode step if a profile ever shows it.
    // Limited: NSCache holds its keys, here the pictures themselves, until it evicts the entry.
    /// One per picture, made once: the first frame shrunk to ~32 px, blurred, and kept for as long as the picture is.
    /// A few hundred microseconds, so it is made where it is first needed, on the main thread.
    nonisolated(unsafe) private static let blurs: NSCache<NSImage, CGImage> = {
        let cache = NSCache<NSImage, CGImage>()
        cache.countLimit = 200
        return cache
    }()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    static func blurred(_ image: NSImage) -> CGImage? {
        if let cached = blurs.object(forKey: image) { return cached }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let full = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let side: CGFloat = 32
        let scale = side / CGFloat(max(full.width, full.height))
        let width = max(1, Int(CGFloat(full.width) * scale))
        let height = max(1, Int(CGFloat(full.height) * scale))
        guard
            let small = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        small.interpolationQuality = .high
        small.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumb = small.makeImage() else { return nil }
        let blurred = CIImage(cgImage: thumb).clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(
            to: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.createCGImage(blurred, from: blurred.extent) else { return nil }
        blurs.setObject(result, forKey: image)
        return result
    }
}
