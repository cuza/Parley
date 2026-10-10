import AppKit
import SwiftUI
import Testing
@testable import Parley

/// Settings ▸ Hidden conversations, hosted at Settings' width: one row per hidden conversation (long names cut, not
/// widening Settings), the list scrolling past a few rows, and a one-line empty state.
@MainActor struct HiddenConversationsTests {
    private func size(_ store: ChatStore) -> CGSize {
        let host = NSHostingView(rootView: HiddenConversationsSection(store: store).frame(width: 380))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
    private func started(many: Int = 0) async -> ChatStore {
        let store = ChatStore(backend: FakeBackend(manyConversations: many))
        await store.start()
        return store
    }

    @Test func growsWithTheListThenScrolls() async {
        let empty = size(await started())
        #expect(empty.width <= 380.5 && empty.height > 0 && empty.height < 30)   // "No hidden conversations", one line
        let store = await started(many: 40)
        for id in store.conversations.prefix(2).map(\.id) { await store.hide(id) }
        let two = size(store)
        #expect(store.hidden.count == 2 && two.width <= 380.5 && two.height > empty.height)
        for id in store.conversations.prefix(30).map(\.id) { await store.hide(id) }
        let many = size(store)
        #expect(store.hidden.count == 32 && many.width <= 380.5 && many.height > two.height && many.height <= 160.5)
    }
}
