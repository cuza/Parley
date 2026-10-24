import AppKit
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Google Chat gives a picture a new token, so a new URL, every time its message loads: the cache keys a picture by its
/// message and place instead, and keeps it on disk, so a relaunch or a reload shows it without fetching it again.
@MainActor struct ImageDiskCacheTests {
    private static var png: Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) {
            NSColor.red.setFill()
            $0.fill()
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    private func picture(token: String) -> ParleyDomain.Attachment {
        var picture = ParleyDomain.Attachment(
            name: "cat.png", contentType: "image/png", kind: .image,
            thumbnailURL: URL(string: "https://chat.google.com/api/get_attachment_url?attachment_token=\(token)"))
        picture.cacheKey = "space/s/t1/m1#0"
        return picture
    }
    @Test func aPictureLoadsFromDiskWhateverItsTokenAfterARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ImageDiskCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = ImageCache.directory
        ImageCache.directory = folder
        defer { ImageCache.directory = saved }
        // Only this picture's entry: clearing the whole shared cache would wipe other tests' pictures mid-test.
        ImageCache.shared.removeObject(forKey: ImageCache.key(picture(token: "first")) as NSString)
        var fetches = 0
        let fetch: (ParleyDomain.Attachment, Bool) async throws -> Data = { _, _ in
            fetches += 1
            return Self.png
        }
        #expect(try await ImageCache.load(picture(token: "first"), fetch) != nil)
        ImageCache.shared.removeObject(forKey: ImageCache.key(picture(token: "first")) as NSString)  // a relaunch: memory is empty, the disk is not
        #expect(try await ImageCache.load(picture(token: "second"), fetch) != nil)
        #expect(fetches == 1)
        #expect(ImageCache.key(picture(token: "first")) == ImageCache.key(picture(token: "second")))
    }
    @Test func pruningKeepsTheMostRecentlyUsedWithinTheLimitAndDropsOldOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ImageDiskCachePrune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date.now
        func put(_ name: String, daysAgo: Double) throws {
            let file = folder.appending(path: name)
            try Data(count: 10_000).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: file.path)
        }
        try put("new", daysAgo: 0)
        try put("older", daysAgo: 1)
        try put("oldest", daysAgo: 2)
        try put("stale", daysAgo: 40)
        let one = try #require(
            folder.appending(path: "new").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
        ImageCache.prune(folder, limit: one * 2, now: now)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["new", "older"])
    }
    @Test func messagesNameTheirPicturesByPlace() throws {
        let proto = Dynamite_Message.with { built in
            built.id.messageID = "m1"
            built.id.parentID.topicID.topicID = "t1"
            built.creator.userID.id = "u1"
            built.annotations = [
                .with { annotation in
                    annotation.type = .uploadMetadata
                    annotation.uploadMetadata.attachmentToken = "tok"
                    annotation.uploadMetadata.contentType = "image/png"
                    annotation.uploadMetadata.contentName = "a.png"
                },
                .with { annotation in
                    annotation.type = .uploadMetadata
                    annotation.uploadMetadata.attachmentToken = "tok2"
                    annotation.uploadMetadata.contentType = "image/png"
                    annotation.uploadMetadata.contentName = "b.png"
                },
            ]
        }
        let message = try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:]))
        #expect(message.attachments.map(\.cacheKey) == ["\(message.id)#0", "\(message.id)#1"])
    }
}
