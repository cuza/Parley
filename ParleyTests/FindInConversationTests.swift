import Testing
@testable import Parley

/// ⌘F: search the open conversation only.
@MainActor struct FindInConversationTests {
    @Test func aScopedSearchOnlyFindsTheConversationsMessages() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.search("the")
        let everywhere = Set(store.searchResults.map(\.conversationID))
        #expect(everywhere.count > 1)
        let room = try #require(everywhere.sorted().first)
        await store.search("the", in: room)
        #expect(!store.searchResults.isEmpty && store.searchResults.allSatisfy { $0.conversationID == room })
    }
    @Test func theSearchPanelNamesItsScope() {
        let room = Conversation(id: "space/s", name: "Design studio", kind: .space, members: [])
        #expect(FinderPanel.prompt(in: room) == "Search in Design studio")
        #expect(FinderPanel.prompt(in: nil) == "Search messages")
    }
}
