import AppKit
import Testing
@testable import Parley

/// Send to Parley (Services and the share sheet): what's shared joins the picked conversation's draft, never sent on
/// its own.
@MainActor struct ShareTests {
    static func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Parley share \(UUID().uuidString).txt")
        try Data("notes".utf8).write(to: url)
        return url
    }
    @Test func sharedTextAndFilesJoinTheDraft() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.setDraft("Here you go", conversation: "alex", thread: nil)
        let url = try Self.file()
        store.share(Shared(text: "https://example.com/plan", files: [url]), to: "alex")
        #expect(store.drafts[store.key("alex", nil)] == "Here you go\nhttps://example.com/plan")
        #expect(store.draftAttachments[store.key("alex", nil)]?.map(\.name) == [url.lastPathComponent])
        #expect(store.messages.filter { $0.conversationID == "alex" && $0.sender.id == store.me.id }.isEmpty)   // nothing sent
    }
    @Test func thePasteboardGivesTextAndFiles() throws {
        let pasteboard = NSPasteboard(name: .init("Parley share test \(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let url = try Self.file()
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        #expect(Shared(pasteboard)?.files == [url])
        pasteboard.clearContents()
        pasteboard.setString("a note", forType: .string)
        #expect(Shared(pasteboard) == Shared(text: "a note", files: []))
        pasteboard.clearContents()
        #expect(Shared(pasteboard) == nil)   // nothing to share
    }
    /// Services ▸ Send to Parley hands what it reads to the app, or says why not.
    @Test func theServiceHandsOverWhatItReads() throws {
        let pasteboard = NSPasteboard(name: .init("Parley service test \(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let service = ShareService()
        var received: [Shared] = []
        service.received = { received.append($0) }
        var problem: NSString?
        pasteboard.clearContents()
        pasteboard.setString("lunch at 1?", forType: .string)
        service.sendToParley(pasteboard, userData: nil, error: &problem)
        pasteboard.clearContents()
        service.sendToParley(pasteboard, userData: nil, error: &problem)
        #expect(received == [Shared(text: "lunch at 1?", files: [])] && problem != nil)
    }
    /// The share sheet's extension hands over a pasteboard by name in a parley://share link: Parley reads it, frees it,
    /// and copies files the extension made (photos, pasted data) out of its container before it's cleaned up.
    @Test func aShareLinkReadsItsPasteboard() throws {
        let name = "dev.cuza.Parley.share.test-\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: .init(name))
        let container = FileManager.default.temporaryDirectory.appending(path: "Containers/dev.cuza.Parley.Share/Data/tmp")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let photo = container.appending(path: "IMG_0001.heic")
        try Data("photo".utf8).write(to: photo)
        pasteboard.clearContents()
        pasteboard.writeObjects([photo as NSURL])
        let shared = try #require(Shared(link: URL(string: "parley://share?pasteboard=\(name)")!))
        #expect(shared.files.map(\.lastPathComponent) == ["IMG_0001.heic"] && shared.files != [photo])   // a copy of Parley's own
        #expect(try Data(contentsOf: shared.files[0]) == Data("photo".utf8))
        #expect(NSPasteboard(name: .init(name)).pasteboardItems?.isEmpty != false)   // freed
        #expect(Shared(link: URL(string: "parley://share")!) == nil && Shared(link: URL(string: "https://chat.google.com/")!) == nil)
    }
}
