import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Google Chat links sent to Parley (`open -a Parley <url>`, a link router set to send Chat links here).
@MainActor struct OpenURLTests {
    private func store() async throws -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        await fake.invite(SpaceListing(id: "space/plans", name: "Plans", invited: true))
        let store = ChatStore(backend: fake)
        await store.start()
        try await store.join(store.rooms.invitations[0])
        return (store, fake)
    }
    @Test func aChatLinkOpensItsConversation() async throws {
        let (store, _) = try await store()
        await store.select("design")
        await store.open(url: try #require(URL(string: "https://chat.google.com/u/0/app/chat/plans")))
        #expect(store.navigation.selectedID == "space/plans" && store.error == nil)
    }
    /// A link that launched Parley waits for the conversation list instead of failing on an empty one.
    @Test func aLinkBeforeTheFirstListWaitsForIt() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.open(url: try #require(URL(string: "https://chat.google.com/room/launch")))
        #expect(store.error == nil)
        await store.start()
        #expect(store.error != nil)  // "space/launch" isn't one of the fake's ids: the waiting link was tried once listed
    }
    /// One this account can't open says so; it is not handed back to the browser, which could send it straight back.
    @Test func aConversationNotInTheSidebarSaysSo() async throws {
        let (store, _) = try await store()
        await store.open(url: try #require(URL(string: "https://chat.google.com/room/elsewhere")))
        #expect(store.error == "This account isn't in the conversation that link goes to.")
    }
    @Test func otherLinksAreIgnored() async throws {
        let (store, _) = try await store()
        let before = store.navigation.selectedID
        await store.open(url: try #require(URL(string: "https://example.com/room/plans")))
        #expect(store.navigation.selectedID == before && store.error == nil)
    }
    /// A Chat link pasted into ⌘K is offered first, and choosing it opens the conversation.
    @Test func aPastedLinkIsOfferedFirstInThePalette() async throws {
        let (store, _) = try await store()
        let text = " https://chat.google.com/room/plans "
        let results = PaletteResults(
            query: text, conversations: store.rooms.conversations, people: [Person(id: "maria", name: "Maria Chen")],
            spaces: [], picked: [])
        let url = try #require(URL(string: "https://chat.google.com/room/plans"))
        #expect(results.items.first == .link(url))
        await store.select("design")
        try await ConversationPalette.open(results.items.first, picked: [], store: store, then: nil, close: {})
        #expect(store.navigation.selectedID == "space/plans")
        #expect(
            PaletteResults(
                query: "https://example.com/room/plans", conversations: [], people: [], spaces: [], picked: []
            ).link == nil)
        #expect(PaletteResults(query: "plans", conversations: [], people: [], spaces: [], picked: []).link == nil)
    }
}

/// A link to a thread's first message opens the thread, as web Chat does; one to a message without replies only shows it.
@MainActor struct ThreadLinkTests {
    @Test func aThreadWithRepliesOpensItsPanel() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        await store.showShared(
            SharedContent.Item(attachment: Attachment(name: "a", kind: .file), date: .now, sender: "", messageID: "d4"),
            in: "design")
        #expect(store.navigation.threadID == "d4" && store.history.highlightedID == "d4")
    }
    @Test func aMessageWithoutRepliesStaysInTheTimeline() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        let plain = try #require(
            store.history.messages.first { $0.conversationID == "design" && $0.threadID == nil && $0.replyCount == 0 })
        await store.showShared(
            SharedContent.Item(
                attachment: Attachment(name: "a", kind: .file), date: .now, sender: "", messageID: plain.id),
            in: "design")
        #expect(store.navigation.threadID == nil && store.history.highlightedID == plain.id)
    }
}
