import Foundation
import Testing
@testable import Parley

/// Opening a message far back in history (a search result, a link, a quote), as web Chat does: the page around it
/// replaces the timeline, the message flashes there among its neighbours, and newer pages load as the reader scrolls
/// down until the window meets the newest messages.
@MainActor struct SearchJumpTests {
    private func started(_ fake: FakeBackend = FakeBackend(longHistory: 600)) async -> (ChatStore, FakeBackend) {
        let store = ChatStore(backend: fake)
        await store.start()
        return (store, fake)
    }
    private func ids(_ store: ChatStore) -> [MessageID] { store.timeline("engineering").map(\.id) }

    @Test func anOldResultOpensInItsNeighbourhood() async throws {
        let (store, _) = await started()
        await store.search("100 ·")
        await store.jump(try #require(store.searchResults.first { $0.id == "e100" }))
        let shown = ids(store)
        let at = try #require(shown.firstIndex(of: "e100"))
        #expect(shown[at - 1] == "e99" && shown[at + 1] == "e101")
        #expect(!shown.contains("e599") && store.detached.contains("engineering") && store.highlightedID == "e100")
    }
    /// A resync while reading an old message keeps the window there; it doesn't pull the reader back to the newest.
    @Test func aResyncKeepsAnOldMessageOpen() async throws {
        let (store, fake) = await started()
        await store.open("engineering", at: "e100")
        #expect(store.detached.contains("engineering"))
        let reads = await fake.listReads
        store.apply(.resync)
        for _ in 0..<100 where await fake.listReads == reads { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.detached.contains("engineering") && ids(store).contains("e100"))
    }
    /// A message that arrives while the conversation reloads isn't in the page the server already read: it stays.
    @Test func aMessageArrivingDuringAReloadStays() async throws {
        let (store, _) = await started(FakeBackend(latency: .milliseconds(150)))
        await store.select("alex")
        async let reload: Void = store.select("alex")   // reselecting reloads the newest page
        try await Task.sleep(for: .milliseconds(40))
        store.apply(.messageUpserted(Message(id: "late", conversationID: "alex", sender: Person(id: "alex", name: "Alex"), text: "just now")))
        await reload
        #expect(store.timeline("alex").contains { $0.id == "late" })
    }
    @Test func scrollingDownLoadsNewerPagesUntilTheWindowMeetsTheNewest() async throws {
        let (store, _) = await started()
        await store.open("engineering", at: "e100")
        for _ in 0..<40 where store.detached.contains("engineering") { await store.loadNewerIfNeeded("engineering") }
        let shown = ids(store)
        #expect(!store.detached.contains("engineering") && shown.last == "e599")
        let numbers = shown.compactMap { Int($0.dropFirst()) }
        #expect(numbers == Array(numbers.first!...599), "contiguous from the window to the newest")
    }
    @Test func olderPagesStillLoadAboveTheWindow() async throws {
        let (store, _) = await started()
        await store.open("engineering", at: "e300")
        let top = try #require(ids(store).first.flatMap { Int($0.dropFirst()) })
        await store.loadOlderIfNeeded("engineering")
        let newTop = try #require(ids(store).first.flatMap { Int($0.dropFirst()) })
        #expect(newTop < top && ids(store).compactMap { Int($0.dropFirst()) } == Array(newTop...ids(store).compactMap { Int($0.dropFirst()) }.last!))
    }
    /// A new message waits below the window until it meets it; sending, or the scroll-down button, returns to the newest.
    @Test func newMessagesWaitBelowAWindowAndSendingReturnsToTheNewest() async throws {
        let (store, fake) = await started()
        await store.open("engineering", at: "e100")
        await fake.simulateIncoming(Message(id: "fresh", conversationID: "engineering", sender: Person(id: "alex", name: "Alex"), text: "new", createdAt: .now))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ids(store).contains("fresh"))
        await store.returnToNewest("engineering")
        #expect(!store.detached.contains("engineering") && ids(store).last == "fresh")
        await store.open("engineering", at: "e100")
        store.setDraft("hi", conversation: "engineering", thread: nil)
        await store.send(conversation: "engineering")
        #expect(!store.detached.contains("engineering") && ids(store).contains("e599"))
    }
    @Test func reopeningTheConversationShowsTheNewest() async throws {
        let (store, _) = await started()
        await store.open("engineering", at: "e100")
        await store.select("engineering")
        #expect(!store.detached.contains("engineering") && ids(store).last == "e599")
    }
}

/// The two requests behind a window, as web Chat sends the first one.
extension AuthTests {
    @Test func aWindowIsListTopicsAroundTheTopicThenNewerThanItsNewest() async throws {
        func topic(_ id: String, at sort: Int64) -> Dynamite_Topic {
            var head = Self.message(id, topic: id, at: sort)
            head.id.parentID.topicID.groupID.spaceID.spaceID = "s9"
            return .with { $0.id.topicID = id; $0.id.groupID.spaceID.spaceID = "s9"; $0.sortTime = sort; $0.replies = [head] }
        }
        let around = Dynamite_ListTopicsResponse.with { $0.topics = [topic("t1", at: 10), topic("t2", at: 20)]; $0.containsLastTopic = false }
        let newer = Dynamite_ListTopicsResponse.with { $0.topics = [topic("t3", at: 30)]; $0.containsLastTopic = true }
        let (backend, exchange) = try await Self.connected([try Self.proto(around), try Self.proto(newer)])
        let window = try await backend.messages(around: "space/s9/t2/t2", in: "space/s9")
        let first = try Dynamite_ListTopicsRequest(serializedBytes: Self.body(exchange.requests[exchange.requests.count - 1]))
        #expect(first.filter.aroundTopic.topicID == "t2" && first.filter.aroundTopic.groupID.spaceID.spaceID == "s9")
        #expect(window.messages.count == 2 && window.hasNewer)
        let next = try await backend.newerMessages(in: "space/s9")
        let second = try Dynamite_ListTopicsRequest(serializedBytes: Self.body(exchange.requests[exchange.requests.count - 1]))
        #expect(second.filter.newerThan == 20 && next.messages.count == 1 && !next.hasNewer)
    }
}
