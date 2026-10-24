import Foundation
import Testing

@testable import Parley

/// Back and Forward: the places opened, conversations, shortcuts and Ask Gemini sessions, walked as a browser does.
@MainActor
struct NavigationHistoryTests {
    /// Back and forward walk the places opened, conversations and shortcuts alike, as a browser does.
    @Test func backAndForwardWalkThePlacesOpened() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let ids = store.rooms.conversations.prefix(2).map(\.id)
        try #require(ids.count == 2)
        await store.select(ids[0])
        await store.openShortcut(.starred)
        await store.select(ids[1])
        await store.goBack()
        #expect(store.navigation.shortcut == .starred)
        await store.goBack()
        #expect(store.navigation.shortcut == nil && store.navigation.selectedID == ids[0])
        #expect(store.canGoForward)
        await store.goForward()
        #expect(store.navigation.shortcut == .starred)
        await store.select(ids[1])  // a new place drops the forward history
        #expect(!store.canGoForward && store.canGoBack)
        await store.select(ids[1])  // reopening the current place adds nothing
        await store.goBack()
        #expect(store.navigation.shortcut == .starred)
    }

    /// An Ask Gemini session fills the page, so Back (⌘[) closes it to Ask Gemini's home before leaving Ask Gemini.
    @Test func backClosesAnAskGeminiSessionFirst() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let other = try #require(store.rooms.conversations.first { $0.app != .gemini }).id
        let gemini = try #require(store.rooms.conversations.first { $0.app == .gemini }).id
        await store.select(other)
        await store.select(gemini)
        await store.openThread(try #require(store.history.messages.first { $0.id == "gs1" }))
        #expect(store.canGoBack)
        await store.goBack()
        #expect(store.navigation.selectedID == gemini && store.navigation.threadID == nil)
        await store.goBack()
        #expect(store.navigation.selectedID == other)
    }

    /// An Ask Gemini session is a place of its own: leaving it and coming Back reopens it, and Forward from its home too.
    @Test func backReturnsToTheAskGeminiSessionLeft() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let other = try #require(store.rooms.conversations.first { $0.app != .gemini }).id
        let gemini = try #require(store.rooms.conversations.first { $0.app == .gemini }).id
        await store.select(gemini)
        await store.openThread(try #require(store.history.messages.first { $0.id == "gs1" }))
        await store.select(other)  // a jump elsewhere
        await store.goBack()
        #expect(store.navigation.selectedID == gemini && store.navigation.threadID == "gs1")
        await store.goBack()
        #expect(store.navigation.selectedID == gemini && store.navigation.threadID == nil)
        await store.goForward()
        #expect(store.navigation.selectedID == gemini && store.navigation.threadID == "gs1")
        await store.goForward()
        #expect(store.navigation.selectedID == other)
    }
    /// Back and Forward skip a conversation that's gone: it can't open, so it's no place to go.
    @Test func backSkipsARemovedConversation() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("general")
        await store.select("alex")
        await store.select("maria")
        store.apply(.conversationRemoved("alex"))
        await store.goBack()
        #expect(store.navigation.selectedID == "general")
    }
}
