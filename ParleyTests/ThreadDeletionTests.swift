import Testing
@testable import Parley

/// Deleting a thread's first message deletes the whole thread, as Google Chat does it ("Thread replies will be deleted").
/// Google sends one deletion, for the first message; its replies go with it, here as on the server.
@MainActor struct ThreadDeletionTests {
    @Test func deletingAThreadsFirstMessageTakesItsRepliesAndClosesIt() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { false }
        await store.start()
        let maria = Person(id: "maria", name: "Maria Chen")
        let head = Message(id: "space/s/t9/t9", conversationID: "design", sender: maria, text: "head")
        store.apply(.messageUpserted(head))
        store.apply(.messageUpserted(Message(id: "space/s/t9/r1", conversationID: "design", threadID: head.id, sender: maria, text: "r1")))
        store.apply(.messageUpserted(Message(id: "space/s/t9/r2", conversationID: "design", threadID: head.id, sender: maria, text: "r2")))
        await fake.setHomeThreads([HomeThread(id: head.id, conversationID: "design", head: head, latest: head, unread: false, time: head.createdAt)])
        try await store.refresh()
        store.threadID = head.id
        store.apply(.messageDeleted(head.id))
        #expect(!store.messages.contains { $0.id == head.id || $0.threadID == head.id })
        #expect(!store.homeThreads.contains { $0.id == head.id })
        #expect(store.threadID == nil)
    }
}
