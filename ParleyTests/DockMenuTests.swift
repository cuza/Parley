import AppKit
import Testing
@testable import Parley

/// The Dock icon's menu: unread conversations (muted ones left out, as the badge leaves them out), then Mark All as Read.
@MainActor struct DockMenuTests {
    private func started() async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        return (store, fake)
    }
    @Test func listsUnreadConversationsWithoutMutedOnes() async {
        let (store, _) = await started()
        let listed = store.dockConversations
        #expect(!listed.isEmpty && listed.count <= 10)
        #expect(listed.allSatisfy { $0.unread > 0 && !$0.muted })
        #expect(Set(listed.map(\.id)) == ["alex", "notebook"])   // the demo's unread ones; Design studio opens, and is read, at start
    }
    @Test func theMenuOpensAConversationAndMarksAllRead() async throws {
        let (store, fake) = await started()
        var opened: [ConversationID] = []
        var markedAll = false
        let menu = DockMenu.make(store.dockConversations, open: { opened.append($0) }, markAllRead: { markedAll = true })
        let first = try #require(menu.items.first)
        #expect(first.title == store.dockConversations[0].name && first.badge?.itemCount == store.dockConversations[0].unread)
        first.target.map { _ = ($0 as AnyObject).perform(first.action, with: first) }
        #expect(opened == [store.dockConversations[0].id])
        let all = try #require(menu.items.last)
        #expect(all.title == "Mark All as Read")
        all.target.map { _ = ($0 as AnyObject).perform(all.action, with: all) }
        #expect(markedAll)
        await store.markAllRead()
        #expect(store.conversations.allSatisfy { $0.unread == 0 })
        #expect(Set(await fake.markedRead).isSuperset(of: ["alex", "notebook"]))
    }
}
