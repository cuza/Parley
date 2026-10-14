import Testing
@testable import Parley

/// ⌘F: the search panel with the open conversation as its "said in" filter.
@MainActor struct FindInConversationTests {
    @Test func aScopedSearchOnlyFindsTheConversationsMessages() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.search("the")
        let everywhere = Set(store.searchResults.map(\.conversationID))
        #expect(everywhere.count > 1)
        let room = try #require(everywhere.sorted().first)
        await store.search("the", filters: SearchFilters(saidIn: [room]))
        #expect(!store.searchResults.isEmpty && store.searchResults.allSatisfy { $0.conversationID == room })
    }
}
