import Foundation
import Testing
@testable import Parley

/// A deleted message stays in its place as a tombstone. Google Chat can't quote it: a send quoting one gets HTTP 404.
@MainActor struct DeletedQuoteTests {
    @Test func aTombstoneIsMarked() throws {
        var proto = Dynamite_Message.with { $0.id.messageID = "m1"; $0.id.parentID.topicID.topicID = "m1"; $0.creator.userID.id = "u1" }
        proto.tombstone.isTombstone = true
        let message = try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:]))
        #expect(message.tombstone && message.text == "Message deleted")
        #expect(try #require(DynamiteMapper.message(.with { $0.id.messageID = "m2"; $0.textBody = "hi" }, in: "space/s", selfID: "me", people: [:])).tombstone == false)
    }
    @Test func launchCachesWithoutTheFlagStillDecode() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Message(id: "m", conversationID: "c", sender: Person(id: "u", name: "U"), text: "x"))) as? [String: Any])
        json["tombstone"] = nil   // a cache written before the flag existed
        #expect(try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json)).tombstone == false)
    }
    @Test func aDeletedMessageCantBeQuoted() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        var gone = Message(id: "gone", conversationID: "design", sender: Person(id: "maria", name: "Maria Chen"), text: "Message deleted")
        gone.tombstone = true
        store.messages.append(gone)
        store.quote(gone)
        #expect(store.quoting.isEmpty)
    }
    /// The three messages stuck on "Couldn't send" quoted a message deleted before they were sent: Retry sends them without it.
    @Test func retryDropsAQuoteOfADeletedMessage() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        var gone = Message(id: "gone", conversationID: "design", sender: Person(id: "maria", name: "Maria Chen"), text: "Message deleted")
        gone.tombstone = true
        let failed = Message(id: "local-1", conversationID: "design", sender: store.me, text: "look", delivery: .failed,
                             quote: QuotedMessage(sender: "Maria Chen", text: "old", id: "gone"))
        store.messages += [gone, failed]
        await store.retry(failed)
        #expect(await fake.sentDrafts.last?.quoting == nil)
        #expect(!store.messages.contains { $0.id == "local-1" } && store.messages.contains { $0.text == "look" && $0.delivery == .sent })
    }
}
