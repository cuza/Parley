import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Trimmed from the documented GIF object (developers.giphy.com/docs/api/schema): sizes are strings.
let giphyFixture = Data(
    """
    {"data":[{"type":"gif","id":"abc123","title":"Happy Dance GIF","rating":"g",
      "images":{"fixed_width":{"url":"https://media2.giphy.com/media/abc123/200w.gif","width":"200","height":"150","webp":"https://media2.giphy.com/media/abc123/200w.webp"},
                "original":{"url":"https://media2.giphy.com/media/abc123/giphy.gif","width":"480","height":"360","size":"1234567","mp4":"https://media2.giphy.com/media/abc123/giphy.mp4"}}},
      {"type":"gif","id":"broken","title":"no renditions","images":{}}],
     "pagination":{"total_count":2,"count":2,"offset":0},"meta":{"status":200,"msg":"OK","response_id":"r1"}}
    """.utf8)

@MainActor struct GiphyTests {
    @Test func emptyQueryAsksForTrending() async throws {
        let exchange = StubExchange([.init(data: giphyFixture)])
        let gifs = try await Giphy.gifs(matching: "  ", key: "k", session: AuthStubProtocol.session(exchange))
        let url = try #require(exchange.requests.first?.url)
        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
        #expect(url.host() == "api.giphy.com" && url.path() == "/v1/gifs/trending")
        #expect(items["rating"] == "pg-13" && items["q"] == nil && items["limit"] != nil)
        #expect(gifs.map(\.id) == ["abc123"])  // a result without both renditions is dropped
    }
    @Test func searchSendsTheQueryAndDecodesRenditions() async throws {
        let exchange = StubExchange([.init(data: giphyFixture)])
        let key = "k-\(UUID())"
        let gif = try #require(
            try await Giphy.gifs(matching: "happy dance", key: key, session: AuthStubProtocol.session(exchange)).first)
        let url = try #require(exchange.requests.first?.url)
        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
        #expect(
            url.path() == "/v1/gifs/search" && items["q"] == "happy dance" && items["rating"] == "pg-13"
                && items["api_key"] == key)
        #expect(gif.title == "Happy Dance GIF")
        #expect(
            gif.preview
                == Giphy.Rendition(
                    url: URL(string: "https://media2.giphy.com/media/abc123/200w.gif")!, width: 200, height: 150))
        #expect(
            gif.original
                == Giphy.Rendition(
                    url: URL(string: "https://media2.giphy.com/media/abc123/giphy.gif")!, width: 480, height: 360))
        let sent = gif.attachment
        #expect(
            sent.kind == .image && sent.contentType == "image/gif" && sent.url == gif.original.url
                && sent.thumbnailURL == gif.original.url)
        #expect(sent.width == 480 && sent.height == 360 && sent.name == "Happy Dance GIF")
    }
    @Test func rateLimitIsExplained() async throws {
        let session = AuthStubProtocol.session(StubExchange([.init(status: 429)]))
        await #expect(throws: Giphy.Failure.rateLimited) {
            try await Giphy.gifs(matching: "x", key: "k", session: session)
        }
    }
}

struct GiphyKeyTests {
    /// Tests never touch the user's own GIPHY key: hosting tests, the app reads and writes a test item.
    @Test func testsUseTheirOwnKeyItem() {
        #expect(Giphy.keyItem.service == "dev.cuza.Parley.giphy.tests")
    }
    @Test func theKeyRoundTripsThroughItsOwnKeychainItem() throws {
        let item = KeychainPassword(service: "dev.cuza.Parley.giphy.tests", account: "api-key")
        try item.set(nil)
        #expect(try item.get() == nil)
        try item.set("abc123")
        #expect(try item.get() == "abc123")
        try item.set("")  // clearing the field removes the item
        #expect(try item.get() == nil)
    }
}

@MainActor struct GifSendTests {
    /// The server drops a client-made URL chip for GIPHY links (the message arrives empty), so a GIF goes out as an upload.
    @Test func aPickedGifIsDownloadedAndSentAsAnUpload() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.navigation.selectedID)
        let bytes = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x21, 0xF9, 4, 1, 0,
            0, 0, 0,
            0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3B,
        ])  // a 1×1 GIF
        var asked: [URL] = []
        store.download = {
            asked.append($0)
            return bytes
        }
        let remote = URL(string: "https://media.giphy.com/media/abc/giphy.gif")!
        await store.sendGif(
            Attachment(
                name: "Party Cat", contentType: "image/gif", kind: .image, thumbnailURL: remote, url: remote, width: 1,
                height: 1),
            conversation: id)
        #expect(asked == [remote])
        let draft = try #require(await fake.sentDrafts.last)
        #expect(draft.uploads.count == 1)
        #expect(draft.uploads.first?.contentType == "image/gif" && draft.uploads.first?.name == "Party Cat.gif")
    }
    @Test func aGifPickedWhileReplyingQuotesTheMessage() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.navigation.selectedID)
        let original = try #require(store.history.messages.last { $0.conversationID == id && !$0.text.isEmpty })
        store.quote(original)
        store.download = { _ in Data([0x47, 0x49, 0x46]) }
        let remote = URL(string: "https://media.giphy.com/media/abc/giphy.gif")!
        await store.sendGif(
            Attachment(name: "Party Cat", contentType: "image/gif", kind: .image, url: remote), conversation: id)
        #expect(await fake.sentDrafts.last?.quoting?.text == original.text)
        #expect(store.drafting.quoting.isEmpty)  // the reply bar closes, as after a typed reply
    }
}
