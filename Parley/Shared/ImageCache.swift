import AppKit
import CryptoKit
import ParleyDomain
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "dev.cuza.Parley", category: "images")

/// Decoded attachment thumbnails, shared by the timeline, its prefetch and the info panel.
@MainActor enum ImageCache {
    /// Decoded pictures in memory, up to 200 or 150 MB of pixels, whichever comes first.
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 150_000_000
        return cache
    }()
    private static var inFlight: [String: Task<NSImage?, Error>] = [:]
    static func key(_ attachment: Attachment) -> String {
        attachment.cacheKey ?? (attachment.thumbnailURL ?? attachment.url)?.absoluteString ?? attachment.name
    }
    /// Where fetched pictures are kept between launches, by key: the app's folder in Caches, as macOS expects (left out
    /// of backups, and cleared by the system when space runs low). Debug builds keep their own, as with the launch cache;
    /// tests and the demo workspace keep none.
    #if DEBUG
        static var directory: URL? = URL.cachesDirectory.appending(
            path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/Images-debug")
    #else
        static var directory: URL? = URL.cachesDirectory.appending(
            path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/Images")
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
        let files =
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)))
            ?? []).map { file in
                let values = try? file.resourceValues(forKeys: keys)
                return (
                    file, used: values?.contentModificationDate ?? .distantPast,
                    size: values?.totalFileAllocatedSize ?? 0
                )
            }.sorted { $0.used > $1.used }  // most recently used first
        var total = 0
        for file in files {
            total += file.size
            if total > limit || file.used < now.addingTimeInterval(-30 * 86_400) {
                try? FileManager.default.removeItem(at: file.0)
            }
        }
    }
    static func cached(_ attachment: Attachment) -> NSImage? { shared.object(forKey: key(attachment) as NSString) }
    /// The thumbnail, from the cache or fetched and decoded off the main thread at display size, then cached.
    /// Concurrent requests for one picture (a row and the prefetch) share a single fetch. Nil: the bytes are not an image.
    static func load(_ attachment: Attachment, _ data: @escaping (Attachment, _ thumbnail: Bool) async throws -> Data)
        async throws -> NSImage?
    {
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
                guard let file, let bytes = try? Data(contentsOf: file), let image = decode(bytes, maxPixels: maxPixels)
                else { return nil }
                try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
                return image
            }.value
            if let kept {
                shared.setObject(kept, forKey: key as NSString, cost: kept.pixelBytes)
                return kept
            }
            let bytes = try await data(attachment, true)
            guard
                let image = await Task.detached(
                    priority: .userInitiated,
                    operation: { () -> NSImage? in
                        guard let image = decode(bytes, maxPixels: maxPixels) else { return nil }
                        if let file {
                            try? FileManager.default.createDirectory(
                                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? bytes.write(to: file, options: .atomic)
                        }
                        return image
                    }
                ).value
            else { return nil }
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
            if maxPixels <= AnimationFrames.maxPixels, let picture = AnimationFrames.image(source, maxPixels: maxPixels)
            {
                return picture
            }
            if let image = NSImage(data: data), image.animated { return image }
            return gif(from: source, maxPixels: maxPixels) ?? NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

extension ImageCache {
    /// An animated picture AppKit won't play, rebuilt as a looping GIF from ImageIO's frames at display size, each for its
    /// own time. Logged by format and frame count only.
    nonisolated static func gif(from source: CGImageSource, maxPixels: Int) -> NSImage? {
        let count = CGImageSourceGetCount(source)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil)
        else { return nil }
        CGImageDestinationSetProperties(
            destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                return nil
            }
            CGImageDestinationAddImage(
                destination, frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay(source, index)]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        log.info(
            "animated picture: \(CGImageSourceGetType(source) as String? ?? "unknown", privacy: .public), \(count, privacy: .public) frames, played as a GIF"
        )
        return NSImage(data: data as Data)
    }
    /// A frame's time, from whichever format's dictionary it has (unclamped first); a tenth of a second when none.
    nonisolated static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let keys = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dictionary, unclamped, clamped) in keys {
            if let values = properties[dictionary] as? [CFString: Any],
                let time = (values[unclamped] ?? values[clamped]) as? Double
            {
                return time
            }
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
