import AppKit
import SwiftUI
import Testing

@testable import Parley

/// What a server search finds joins the list, so ":" suggestions and the picker can show it.
@MainActor struct CustomEmojiSearchStoreTests {
    @Test func searchResultsJoinTheList() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.loadCustomEmoji()
        let before = store.lookups.customEmoji.map(\.id)
        store.searchCustomEmoji(matching: "sam")
        await eventually { store.lookups.customEmoji.count > before.count }
        #expect(store.lookups.customEmoji.map(\.id) == before + [FakeBackend.searchOnlyEmoji.id])
        store.searchCustomEmoji(matching: "sam")  // found again: still once
        #expect(store.lookups.customEmoji.filter { $0.id == FakeBackend.searchOnlyEmoji.id }.count == 1)
    }
}
