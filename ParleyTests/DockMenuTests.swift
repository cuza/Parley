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
    /// The store sets the badge, not a window, so it keeps up with every window closed.
    @Test func theBadgeFollowsTheUnreadCountWithoutAWindow() async {
        let store = ChatStore(backend: FakeBackend())
        var shown: [String?] = []
        store.onBadge = { shown.append($0) }
        #expect(shown == [nil])
        await store.start()
        #expect(store.unreadCount > 0 && shown.last == String(store.unreadCount + 1))   // and General's unread thread
        await store.markAllRead()
        #expect(shown.last == .some(nil))
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 != $1 })   // only changes reach the Dock
    }
    /// A followed thread's new reply counts once, as Home marks it, unless its conversation is muted.
    @Test func theBadgeCountsUnreadThreadsOutsideMutedConversations() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let thread = try #require(store.homeThreads.first { $0.unread })
        #expect(store.badgeCount == store.unreadCount + 1)
        await store.setMuted(true, thread.conversationID)
        #expect(store.badgeCount == store.unreadCount)
        await store.setMuted(false, thread.conversationID)
        await store.openHomeThread(thread)
        #expect(store.badgeCount == store.unreadCount)
    }
    /// A message in the conversation on screen while Parley is in the background stays unread until I'm back, as in Messages.
    @Test func aMessageInTheOpenConversationInTheBackgroundCountsUntilIComeBack() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let open = try #require(store.selectedID)
        let before = store.badgeCount, reads = await fake.markedRead.count
        store.isAppActive = { false }
        await fake.simulateIncoming(Message(id: "away", conversationID: open, sender: Person(id: "alex", name: "Alex"), text: "new", createdAt: .now))
        await eventually { store.badgeCount == before + 1 }
        #expect(store.conversations.first { $0.id == open }?.unread == 1)
        #expect(await fake.markedRead.count == reads)   // not read while I'm away
        store.isAppActive = { true }
        await store.appBecameActive()
        #expect(store.conversations.first { $0.id == open }?.unread == 0 && store.badgeCount == before)
        #expect(await fake.markedRead.count == reads + 1)
    }
    /// A reply that came while I was away, in the thread on screen, is read when I'm back, on the server too.
    @Test func comingBackReadsTheThreadOnScreen() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { true }
        await store.start()
        let head = try #require(store.homeThreads.first { $0.unread }).head
        await store.select(head.conversationID)
        await store.openThread(head)
        #expect(store.unreadThreadCount == 0)
        store.isAppActive = { false }
        await fake.simulateIncoming(Message(id: "away-reply", conversationID: head.conversationID, threadID: head.id,
                                            sender: Person(id: "alex", name: "Alex"), text: "while you were out", createdAt: .now))
        await eventually { store.unreadThreadCount == 1 }
        #expect(store.unreadThreadCount == 1)
        let reads = await fake.threadsRead.count
        store.isAppActive = { true }
        await store.appBecameActive()
        #expect(store.unreadThreadCount == 0 && store.badgeCount == store.unreadCount)
        #expect(await fake.threadsRead.count == reads + 1)
    }
    /// Home lists threads only from conversations in the sidebar; the badge counts the same ones.
    @Test func threadsOfConversationsNotInTheSidebarDontCount() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let alex = Person(id: "alex", name: "Alex")
        let head = Message(id: "x1", conversationID: "elsewhere", sender: alex, text: "head", createdAt: .now, replyCount: 1)
        let reply = Message(id: "x1r", conversationID: "elsewhere", threadID: "x1", sender: alex, text: "reply", createdAt: .now)
        await fake.setHomeThreads([HomeThread(id: "x1", conversationID: "elsewhere", head: head, latest: reply, unread: true, time: .now)])
        try await store.refresh()
        #expect(store.homeThreads.count == 1 && store.unreadThreadCount == 0)
    }
    /// Mark All as Read reads Home's threads on the server too, so they don't come back unread.
    @Test func markAllReadReadsThreadsOnTheServer() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let thread = try #require(store.homeThreads.first { $0.unread })
        await store.markAllRead()
        #expect(await fake.threadsRead.contains(thread.id))
    }
    /// Unread messages saved from last time show at launch, before anything changes.
    @Test func theBadgeShowsUnreadThatWasThereBeforeTheDock() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        var shown: [String?] = []
        store.onBadge = { shown.append($0) }
        #expect(store.unreadCount > 0 && shown == [String(store.unreadCount + 1)])
        await store.markAllRead()
        #expect(shown.last == .some(nil))
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 != $1 })   // only changes reach the Dock
    }
}
