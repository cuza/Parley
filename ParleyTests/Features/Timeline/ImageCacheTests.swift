import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// `ImageCache`: pictures decode at the size they are drawn, GIFs keep their frames, and a cached one is on screen at once.
@MainActor struct ImageCacheTests {
    @Test func aStillImageIsDownsampledAndAGIFKeepsItsFrames() async throws {
        let png = try await FakeBackend().attachmentData(
            Attachment(name: "big.png", kind: .image, width: 2000, height: 1000), thumbnail: true)
        let image = try #require(ImageCache.decode(png, maxPixels: 500))
        #expect(image.size == NSSize(width: 500, height: 250))
        let gif = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(gif, "com.compuserve.gif" as CFString, 3, nil))
        let frame = try #require(NSBitmapImageRep(data: png)?.cgImage)
        for _ in 0..<3 { CGImageDestinationAddImage(destination, frame, nil) }
        #expect(CGImageDestinationFinalize(destination))
        let animated = try #require(ImageCache.decode(gif as Data, maxPixels: 1000))
        let rep = try #require(animated.representations.first as? NSBitmapImageRep)
        #expect(rep.value(forProperty: .frameCount) as? Int == 3)
        #expect(try #require(ImageCache.decode(gif as Data, maxPixels: 100)).decodedFrames?.frames.count == 3)  // emoji-sized: decoded whole
    }
    @Test func aCachedPictureShowsOnTheFirstFrame() throws {
        let picture = Attachment(
            name: "seen.png", kind: .image, url: URL(string: "https://example.com/seen-\(UUID())"), width: 320,
            height: 240)
        let seeded = NSImage(size: NSSize(width: 32, height: 24))
        ImageCache.shared.setObject(seeded, forKey: ImageCache.key(picture) as NSString)
        let host = NSHostingView(
            rootView: AttachmentView(attachment: picture, load: { _, _ in throw URLError(.notConnectedToInternet) }))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        func images(_ view: NSView) -> [NSImageView] {
            ((view as? NSImageView).map { [$0] } ?? []) + view.subviews.flatMap(images)
        }
        #expect(images(host).contains { $0.image === seeded })
    }
}
