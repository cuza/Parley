import CoreImage
import CryptoKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "dev.cuza.Parley", category: "images")

/// One attachment in a bubble: images, GIFs and video posters inline; files and links as a chip.
/// `load(attachment, thumbnail)` returns the bytes (`ChatStore.attachmentData`). Clicks, drags and the menu are
/// handled by the row's `AttachmentHostView`.
struct AttachmentView: View {
    let attachment: Attachment
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    var own = false   // in my bubble: a voice message draws in my bubble's text colour
    var transcriptOpen = false
    var toggleTranscript: () -> Void = {}
    var dismissCard: () -> Void = {}
    var clickCard: (String?, Data, [Card.Input]) async -> Void = { _, _, _ in }
    var corners: RowLayout.Corners?   // a picture filling its bubble: the corners at the bubble's (the others are small)
    @State private var loaded: (key: String, image: NSImage)?
    @State private var failedKey: String?
    /// The row view is recycled: only this attachment's picture or failure shows, and a cached picture shows on the
    /// first frame, without a placeholder in between.
    private var image: NSImage? { loaded?.key == key ? loaded?.image : ImageCache.cached(attachment) }
    private var failed: Bool { failedKey == key }
    private var key: String { ImageCache.key(attachment) }

    var body: some View {
        if attachment.kind == .voice { VoiceMessageView(attachment: attachment, own: own, load: load, transcriptOpen: transcriptOpen, toggleTranscript: toggleTranscript) }
        else if let card = attachment.card { CardView(card: card, dismiss: dismissCard, expanded: transcriptOpen, toggle: toggleTranscript, click: { await clickCard(card.id, $0, $1) })
            .id(attachment.cacheKey) }   // a recycled row starts with empty fields
        else if attachment.kind == .image || attachment.kind == .video { media } else if attachment.domain != nil { card } else { chip }
    }

    /// Link preview: image on top, cropped to fill; then title, snippet and domain.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.quaternary).frame(height: cardImageHeight)
                .overlay(alignment: .top) {   // top-aligned: a document preview shows its first lines
                    if let image { Image(nsImage: image).resizable().scaledToFill().transition(.opacity) }
                    else if failed {   // as Google Chat shows a file it can't preview (no access): its type's icon, large
                        Image(systemName: driveSymbol ?? "link").font(.system(size: driveSymbol == nil ? 13 : 56))
                            .foregroundStyle(own ? ink.opacity(0.8) : Color.secondary).frame(maxHeight: .infinity)
                    }
                }
                .overlay {
                    if attachment.isVideoLink {
                        Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white, .black.opacity(0.5))
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(failed && attachment.untitledDrive ? "You don't have access to this file" : attachment.name).font(.callout.weight(.semibold)).lineLimit(2).foregroundStyle(text(.primary, 1))
                if let snippet = attachment.snippet, snippet != attachment.name {
                    Text(snippet).font(.caption).foregroundStyle(text(.secondary, 0.8)).lineLimit(2)
                }
                Text(attachment.domain ?? "").font(.caption2).foregroundStyle(text(.tertiary, 0.65)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // the row sizes it (RowLayout.attachmentSize)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .help(attachment.url?.absoluteString ?? attachment.name)
        .task(id: attachment) { await loadThumbnail() }
    }
    private func radius(_ corner: RowLayout.Corners) -> CGFloat { corners.map { $0.contains(corner) ? RowLayout.mediaRadius : RowLayout.mediaInnerRadius } ?? RowLayout.mediaRadius }
    private var cardImageHeight: CGFloat { attachment.cardImageHeight }
    private var media: some View {
        ZStack {
            if let image { MediaPicture(image: image).transition(.opacity) } else {
                Rectangle().fill(.quaternary)
                if failed { Image(systemName: "photo").foregroundStyle(.secondary) } else { ProgressView().controlSize(.small) }
            }
            if attachment.kind == .video {
                Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white, .black.opacity(0.6))
            }
        }
        .overlay(alignment: .topLeading) {   // Telegram's badge on an animated picture, on one taller than 80
            GeometryReader { geometry in
                if attachment.contentType == "image/gif", geometry.size.height > 80 {
                    Text("GIF").font(.system(size: 10)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule()).padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // the row sizes it: mediaSize, narrowed to fit the bubble
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius(.topLeft), bottomLeadingRadius: radius(.bottomLeft),
                                          bottomTrailingRadius: radius(.bottomRight), topTrailingRadius: radius(.topRight), style: .circular))   // circular, as the bubble's arcs: a continuous corner is rounder and leaves a sliver of the bubble
        .overlay {   // a hairline round a picture with no bubble: a white picture would melt into a white background
            if corners == nil { RoundedRectangle(cornerRadius: RowLayout.mediaRadius, style: .circular).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
        }
        .help(attachment.name)
        .task(id: attachment) { await loadThumbnail() }
    }

    private var chip: some View {
        HStack(spacing: 8) {
            if attachment.kind == .call {   // as Google Chat shows a call: a video icon, red when missed
                Image(systemName: attachment.call == .missed ? "video.slash.fill" : "video.fill").font(.system(size: 18))
                    .foregroundStyle(attachment.call == .missed ? Color.red : own ? ink : Color.secondary).frame(width: 28, height: 28)   // my bubble's text colour on it bubble
            } else if let driveSymbol {
                Image(systemName: driveSymbol).font(.system(size: 20)).foregroundStyle(text(.secondary, 0.9)).frame(width: 28, height: 28)
            } else {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1).truncationMode(.middle).foregroundStyle(text(.primary, 1))
                Text(detail).font(.caption).foregroundStyle(text(.secondary, 0.8)).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 280, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .help(attachment.url?.absoluteString ?? attachment.name)
    }
    private var type: UTType? { attachment.utType }
    /// Card and chip background: set off from my bubble so its text stands out; a light tint elsewhere.
    private var fill: AnyShapeStyle { own ? AnyShapeStyle(Color(nsColor: BubblePalette.ownWell)) : AnyShapeStyle(.quaternary.opacity(0.6)) }
    /// Card and chip text: my bubble's text colour on it, the system's levels elsewhere.
    private var ink: Color { Color(nsColor: BubblePalette.ownInk) }
    private func text(_ level: HierarchicalShapeStyle, _ white: Double) -> AnyShapeStyle {
        own ? AnyShapeStyle(ink.opacity(white)) : AnyShapeStyle(level)
    }
    /// Google Docs, Sheets and Slides have no system file type: a symbol for each, and a page for other Drive-native files.
    private var driveSymbol: String? {
        let type = attachment.contentType
        guard type.hasPrefix("application/vnd.google-apps") || attachment.untitledDrive else { return nil }
        // Google Chat sends the editors' own names: kix (Docs), ritz (Sheets), punch (Slides).
        return type.hasSuffix(".spreadsheet") || type.hasSuffix(".ritz") ? "tablecells.fill"
            : type.hasSuffix(".presentation") || type.hasSuffix(".punch") ? "rectangle.on.rectangle.angled.fill" : "doc.fill"
    }
    private var icon: NSImage {
        if attachment.kind == .link && type == nil { return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(for: type ?? .data)
    }
    private var detail: String { attachment.detail }

    /// Fetches and decodes the picture unless it is cached; one that had to load fades in (0.2 s, as Telegram).
    private func loadThumbnail() async {
        let key = self.key
        guard image == nil else { return }
        do {
            guard let decoded = try await ImageCache.load(attachment, load) else { failedKey = key; return }
            withAnimation(.easeIn(duration: 0.2)) { loaded = (key, decoded) }
        } catch { if !(error is CancellationError) { failedKey = key } }
    }
}

/// Sizes `AttachmentView` draws at, known before any bytes load; `RowLayout` reserves the same.
extension Attachment {
    /// Known image size scaled to the 320-pt card width, capped so a tall image doesn't dominate the row.
    var cardImageHeight: CGFloat {
        guard let w = width, let h = height else { return 160 }
        return min(180, max(80, 320 * CGFloat(h) / CGFloat(w)))
    }
    /// Fits the known size into 320×240 so the row keeps its height while the bytes load.
    var mediaSize: CGSize {
        let w = CGFloat(width ?? 320), h = CGFloat(height ?? 240)
        let scale = min(1, 320 / w, 240 / h)
        return CGSize(width: max(60, w * scale).rounded(), height: max(60, h * scale).rounded())   // whole points, so edges land on pixels
    }
    var utType: UTType? { UTType(mimeType: contentType) }
    // ponytail: the wire has no byte size; the chip shows the kind instead.
    /// A link to a video (YouTube), drawn with a play button over its picture.
    var isVideoLink: Bool { kind == .link && domain == "youtube.com" }
    var detail: String {
        if contentType == Self.calendarType { return "Google Calendar" }
        if contentType == Self.taskType { return "Google Tasks" }
        return kind == .call ? "Google Meet" : kind == .link ? url?.host() ?? "Link" : utType?.localizedDescription ?? "File"
    }
    static let calendarType = "text/calendar", taskType = "application/x-google-task"
    /// A Drive file Google Chat named only by its kind: when its preview fails, the viewer can't open it, and the card says so.
    static let untitledDrive = "Google Drive file"
    var untitledDrive: Bool { kind == .link && [Self.untitledDrive, "Google Doc", "Google Sheet", "Google Slides", "Google Form"].contains(name) }
}

/// Decoded attachment thumbnails, shared by the timeline, its prefetch and the info panel.
@MainActor enum ImageCache {
    /// Decoded pictures in memory, up to 200 or 150 MB of pixels, whichever comes first.
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 200; cache.totalCostLimit = 150_000_000; return cache
    }()
    private static var inFlight: [String: Task<NSImage?, Error>] = [:]
    static func key(_ attachment: Attachment) -> String { attachment.cacheKey ?? (attachment.thumbnailURL ?? attachment.url)?.absoluteString ?? attachment.name }
    /// Where fetched pictures are kept between launches, by key: the app's folder in Caches, as macOS expects (left out
    /// of backups, and cleared by the system when space runs low). Debug builds keep their own, as with the launch cache;
    /// tests and the demo workspace keep none.
    #if DEBUG
    static var directory: URL? = URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/Images-debug")
    #else
    static var directory: URL? = URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/Images")
    #endif
    /// At most this much on disk; past it, the least recently used pictures go first.
    nonisolated static let diskLimit = 500_000_000
    private static func file(_ key: String) -> URL? {
        directory?.appending(path: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    /// Once a launch, off the main thread: removes pictures not used for 30 days, then the least recently used until the
    /// rest fit `diskLimit`. Using a picture touches its file.
    private static let prune: Void = {
        guard let directory else { return }
        Task.detached(priority: .background) { prune(directory, limit: diskLimit) }
    }()
    nonisolated static func prune(_ directory: URL, limit: Int, now: Date = .now) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []).map { file in
            let values = try? file.resourceValues(forKeys: keys)
            return (file, used: values?.contentModificationDate ?? .distantPast, size: values?.totalFileAllocatedSize ?? 0)
        }.sorted { $0.used > $1.used }   // most recently used first
        var total = 0
        for file in files {
            total += file.size
            if total > limit || file.used < now.addingTimeInterval(-30 * 86_400) { try? FileManager.default.removeItem(at: file.0) }
        }
    }
    static func cached(_ attachment: Attachment) -> NSImage? { shared.object(forKey: key(attachment) as NSString) }
    /// The thumbnail, from the cache or fetched and decoded off the main thread at display size, then cached.
    /// Concurrent requests for one picture (a row and the prefetch) share a single fetch. Nil: the bytes are not an image.
    static func load(_ attachment: Attachment, _ data: @escaping (Attachment, _ thumbnail: Bool) async throws -> Data) async throws -> NSImage? {
        if let cached = cached(attachment) { return cached }
        let key = key(attachment)
        if let running = inFlight[key] { return try await running.value }
        let maxPixels = attachment.displayPixels
        _ = prune
        let file = file(key)
        let task = Task<NSImage?, Error> {
            defer { inFlight[key] = nil }
            // From disk when an earlier launch kept it (touched, so pruning keeps what is used), else fetched and kept.
            let kept = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let file, let bytes = try? Data(contentsOf: file), let image = decode(bytes, maxPixels: maxPixels) else { return nil }
                try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
                return image
            }.value
            if let kept { shared.setObject(kept, forKey: key as NSString, cost: kept.pixelBytes); return kept }
            let bytes = try await data(attachment, true)
            guard let image = await Task.detached(priority: .userInitiated, operation: { () -> NSImage? in
                guard let image = decode(bytes, maxPixels: maxPixels) else { return nil }
                if let file {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? bytes.write(to: file, options: .atomic)
                }
                return image
            }).value else { return nil }
            shared.setObject(image, forKey: key as NSString, cost: image.pixelBytes)
            return image
        }
        inFlight[key] = task
        return try await task.value
    }
    /// Downsampled to `maxPixels` on its longer side and decoded now, so drawing it costs nothing on the main thread.
    /// An animated GIF or PNG is kept whole: `AnimatedImage` and `NSImage.drawFrame` play its frames. An animated WebP (as
    /// Google serves animated custom emoji), which NSImage splits into separate pictures, is rebuilt as a GIF first.
    nonisolated static func decode(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetCount(source) > 1 {
            if maxPixels <= AnimationFrames.maxPixels, let picture = AnimationFrames.image(source, maxPixels: maxPixels) { return picture }
            if let image = NSImage(data: data), image.animated { return image }
            return gif(from: source, maxPixels: maxPixels) ?? NSImage(data: data)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

extension ImageCache {
    /// An animated picture AppKit won't play, rebuilt as a looping GIF from ImageIO's frames at display size, each for its
    /// own time. Logged by format and frame count only.
    nonisolated static func gif(from source: CGImageSource, maxPixels: Int) -> NSImage? {
        let count = CGImageSourceGetCount(source), data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay(source, index)]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        log.info("animated picture: \(CGImageSourceGetType(source) as String? ?? "unknown", privacy: .public), \(count, privacy: .public) frames, played as a GIF")
        return NSImage(data: data as Data)
    }
    /// A frame's time, from whichever format's dictionary it has (unclamped first); a tenth of a second when none.
    nonisolated static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let keys = [(kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
                    (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                    (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)]
        for (dictionary, unclamped, clamped) in keys {
            if let values = properties[dictionary] as? [CFString: Any], let time = (values[unclamped] ?? values[clamped]) as? Double { return time }
        }
        return 0.1
    }
}

extension NSImage {
    /// What its pixels take in memory (4 bytes each), as a cache's cost.
    var pixelBytes: Int {
        let rep = representations.first
        let pixels = (rep?.pixelsWide ?? 0) * (rep?.pixelsHigh ?? 0)
        return 4 * (pixels > 0 ? pixels : Int(size.width * size.height)) * (decodedFrames?.frames.count ?? 1)
    }
}

extension Attachment {
    /// The longer side, in pixels, that the timeline draws this picture at: the media frame, or the link card,
    /// on the sharpest screen attached.
    // ponytail: a card is cropped to fill 320 pt wide, so 640 pt covers all but extreme panoramas.
    @MainActor var displayPixels: Int {
        let points = kind == .image || kind == .video ? max(mediaSize.width, mediaSize.height) : 640
        return Int(points * (NSScreen.screens.map(\.backingScaleFactor).max() ?? 2))
    }
}

/// A small animation (a custom emoji) decoded whole off the main thread, at the size it shows, and attached to its
/// NSImage: every frame is ready to draw, so scrolling past hundreds of them decodes nothing on the main thread. Drawn
/// as an image, the NSImage is the first frame; `NSImage.drawFrame` and `AnimatedImage` play the rest.
final class AnimationFrames: NSObject {
    /// Animations up to this many pixels a side are decoded whole; bigger ones (GIFs, media) play through NSImageView,
    /// which decodes a frame at a time.
    nonisolated static let maxPixels = 256
    let frames: [NSBitmapImageRep], durations: [TimeInterval]
    nonisolated private init(frames: [NSBitmapImageRep], durations: [TimeInterval]) { self.frames = frames; self.durations = durations }
    nonisolated(unsafe) fileprivate static let key = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    nonisolated static func image(_ source: CGImageSource, maxPixels: Int) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        var frames: [NSBitmapImageRep] = [], durations: [TimeInterval] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            frames.append(NSBitmapImageRep(cgImage: frame))
            durations.append(ImageCache.delay(source, index))
        }
        guard let first = frames.first else { return nil }
        let image = NSImage(size: NSSize(width: first.pixelsWide, height: first.pixelsHigh))
        image.addRepresentation(first)
        objc_setAssociatedObject(image, key, AnimationFrames(frames: frames, durations: NSImage.playable(durations)), .OBJC_ASSOCIATION_RETAIN)
        return image
    }
}
extension NSImage {
    /// Set on a small animation `ImageCache` decoded whole (`AnimationFrames`).
    nonisolated var decodedFrames: AnimationFrames? { objc_getAssociatedObject(self, AnimationFrames.key) as? AnimationFrames }
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
        CATransaction.begin(); CATransaction.setDisableActions(true); frames.frame = bounds; CATransaction.commit()
    }
    /// Decoded frames play as a Core Animation keyframe animation, which the render server runs with no work on the main
    /// thread, in step with every other copy (the same clock as `NSImage.drawFrame`).
    private func show() {
        frames.removeAnimation(forKey: "frames")
        guard let decoded = image?.decodedFrames else {
            frames.contents = nil
            gif.image = image; gif.isHidden = false
            return
        }
        gif.image = nil; gif.isHidden = true
        let pictures = decoded.frames.compactMap(\.cgImage)
        frames.contents = pictures.first
        let loop = decoded.durations.reduce(0, +)
        guard pictures.count == decoded.durations.count, pictures.count > 1, loop > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = pictures
        var start = 0.0, keyTimes: [NSNumber] = []
        for duration in decoded.durations { keyTimes.append(NSNumber(value: start / loop)); start += duration }
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
        blur.contentsGravity = .resizeAspectFill; blur.masksToBounds = true; blur.magnificationFilter = .linear
        layer?.addSublayer(blur)
        blur.addSublayer(veil)   // Telegram's: half the background's colour over the blur, so it reads as fill, not picture
        picture.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(picture)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blur.frame = bounds; veil.frame = blur.bounds
        effectiveAppearance.performAsCurrentDrawingAppearance { veil.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor }
        CATransaction.commit()
        guard let size = image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { picture.frame = bounds; return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        if bounds.width - fitted.width <= bounds.width * Self.stretchTolerance, bounds.height - fitted.height <= bounds.height * Self.stretchTolerance {
            picture.imageScaling = .scaleAxesIndependently; picture.frame = bounds; blur.isHidden = true
        } else {
            picture.imageScaling = .scaleProportionallyUpOrDown; picture.frame = bounds; blur.isHidden = false
        }
    }

    /// One per picture, made once: the first frame shrunk to ~32 px, blurred, and kept for as long as the picture is.
    /// A few hundred microseconds, so it is made where it is first needed, on the main thread.
    // ponytail: synchronous on first show; move it to the decode step if a profile ever shows it.
    // Limited: NSCache holds its keys, here the pictures themselves, until it evicts the entry.
    nonisolated(unsafe) private static let blurs: NSCache<NSImage, CGImage> = { let cache = NSCache<NSImage, CGImage>(); cache.countLimit = 200; return cache }()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    static func blurred(_ image: NSImage) -> CGImage? {
        if let cached = blurs.object(forKey: image) { return cached }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let full = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let side: CGFloat = 32, scale = side / CGFloat(max(full.width, full.height))
        let w = max(1, Int(CGFloat(full.width) * scale)), h = max(1, Int(CGFloat(full.height) * scale))
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .high
        small.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let thumb = small.makeImage() else { return nil }
        let blurred = CIImage(cgImage: thumb).clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.createCGImage(blurred, from: blurred.extent) else { return nil }
        blurs.setObject(result, forKey: image)
        return result
    }
}
