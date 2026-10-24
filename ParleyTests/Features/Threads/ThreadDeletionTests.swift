import Testing

@testable import Parley
@testable import ParleyDomain

/// Deleting a thread's first message deletes the whole thread, as Google Chat does it ("Thread replies will be deleted").
/// Google sends one deletion, for the first message; its replies go with it, here as on the server.
@MainActor struct ThreadDeletionTests {
    @Test func deletingAThreadsFirstMessageTakesItsRepliesAndClosesIt() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { false }
        await store.start()
        let head = Message.fixture("head", id: "space/s/t9/t9", in: "design", at: .now)
        store.apply(.messageUpserted(head))
        store.apply(
            .messageUpserted(
                .fixture("r1", id: "space/s/t9/r1", in: "design", thread: ThreadID(head: head.id), at: .now)))
        store.apply(
            .messageUpserted(
                .fixture("r2", id: "space/s/t9/r2", in: "design", thread: ThreadID(head: head.id), at: .now)))
        await fake.setHomeThreads([
            HomeThread(
                id: ThreadID(head: head.id), conversationID: "design", head: head, latest: head, unread: false,
                time: head.createdAt)
        ])
        try await store.refresh()
        store.navigation.setPane(nil) { $0.openThread(ThreadID(head: head.id)) }
        store.apply(.messageDeleted(head.id))
        #expect(!store.history.messages.contains { $0.id == head.id || $0.threadID == ThreadID(head: head.id) })
        #expect(!store.rooms.homeThreads.contains { $0.id == ThreadID(head: head.id) })
        #expect(store.navigation.threadID == nil)
    }
}
