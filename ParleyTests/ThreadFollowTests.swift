import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Parley

/// Thread read state and following, as Google Chat sends them.
extension AuthTests {
    private static func requests(_ exchange: StubExchange, _ path: String) -> [Data] {
        exchange.requests.filter { $0.url?.path == "/api/\(path)" }.map(Self.body)
    }
    /// mark_topic_readstate {1 TopicId {2 topic id, 3 group id}, 2 the newest reply's time in µs}.
    @Test func aThreadIsMarkedReadUpToItsNewestReply() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_MarkTopicReadstateResponse())])
        try await backend.markThreadRead("space/x/t1/t1", upTo: Date(timeIntervalSince1970: 1_791_898_983.470_623))
        let sent = try Dynamite_MarkTopicReadstateRequest(serializedBytes: try #require(Self.requests(exchange, "mark_topic_readstate").first))
        #expect(sent.topicID.topicID == "t1" && sent.topicID.groupID.spaceID.spaceID == "x")
        #expect(sent.lastReadTime == 1_791_898_983_470_623)
    }
    /// mark_Topic_mute_state {1 TopicId, 2 muted}: following is not muted.
    @Test func followingAThreadUnmutesItAndUnfollowingMutesIt() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_MarkTopicMuteStateResponse()), try Self.proto(Dynamite_MarkTopicMuteStateResponse())])
        try await backend.setFollowing(false, thread: "space/x/t1/t1")
        try await backend.setFollowing(true, thread: "space/x/t1/t1")
        let sent = try Self.requests(exchange, "mark_Topic_mute_state").map { try Dynamite_MarkTopicMuteStateRequest(serializedBytes: $0) }
        #expect(sent.map(\.muted) == [true, false])
        #expect(sent.allSatisfy { $0.topicID.topicID == "t1" && $0.topicID.groupID.spaceID.spaceID == "x" })
    }
}

/// The store: an open thread is read on the server, and following shows at once and rolls back on failure.
@MainActor struct ThreadFollowStoreTests {
    private func started() async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { true }
        await store.start()
        await store.select("general")
        return (store, fake)
    }
    @Test func openingAThreadMarksItReadAndANewReplyAgain() async throws {
        let (store, fake) = await started()
        let head = try #require(store.messages.first { $0.id == "g1" })
        await store.openThread(head)
        #expect(await fake.threadsRead == ["g1"])
        store.apply(.messageUpserted(Message(id: "g1r2", conversationID: "general", threadID: "g1", sender: Person(id: "maria", name: "Maria Chen"), text: "more")))
        try await until { await fake.threadsRead.count == 2 }
        #expect(await fake.threadsRead == ["g1", "g1"])
        #expect(store.homeThreads.first { $0.id == "g1" }?.unread != true)
    }
    @Test func followingShowsAtOnceAndRollsBackWhenRefused() async throws {
        let (store, fake) = await started()
        store.apply(.threadFollowChanged("g1", following: true))
        await store.setFollowing(false, thread: "g1")
        #expect(!store.isFollowing("g1"))
        #expect(await fake.changes.last == "unfollow g1")
        #expect(!store.homeThreads.contains { $0.id == "g1" })   // Home lists followed threads only
        await fake.simulateChangeFailure()
        await store.setFollowing(true, thread: "g1")
        #expect(!store.isFollowing("g1") && store.error != nil)   // refused: back to not followed, and it says why
    }
    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 where !(await condition()) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// The thread pane's bell: says what a click does, and does it.
@MainActor struct ThreadFollowButtonTests {
    @Test func theBellUnfollowsAFollowedThreadAndSaysSo() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        store.apply(.threadFollowChanged("g1", following: true))
        let bell = ThreadFollowButton(store: store, thread: "g1")
        #expect(bell.label == "Unfollow thread")
        await bell.toggle()
        #expect(!store.isFollowing("g1") && bell.label == "Follow thread")
        #expect(await fake.changes.last == "unfollow g1")
    }
}

/// "Mark as unread" from a message: unread from that message on, as Google Chat marks it (its time − 1 µs).
extension AuthTests {
    private static func markUnreadRequests(_ exchange: StubExchange, _ path: String) -> [Data] {
        exchange.requests.filter { $0.url?.path == "/api/\(path)" }.map(Self.body)
    }
    @Test func markingUnreadFromAMessageSendsItsTimeLessOne() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_SetMarkAsUnreadTimestampResponse()),
                                                            try Self.proto(Dynamite_SetTopicUnreadTimestampResponse())])
        let at = Date(timeIntervalSince1970: 1_791_000_000.000_500)
        try await backend.markUnread(from: Message(id: "space/x/t1/t1", conversationID: "space/x", sender: Person(id: "m", name: "M"), text: "a", createdAt: at))
        try await backend.markUnread(from: Message(id: "space/x/t1/r1", conversationID: "space/x", threadID: "space/x/t1/t1", sender: Person(id: "m", name: "M"), text: "b", createdAt: at))
        let flat = try Dynamite_SetMarkAsUnreadTimestampRequest(serializedBytes: try #require(Self.markUnreadRequests(exchange, "set_mark_as_unread_timestamp").first))
        #expect(flat.groupID.spaceID.spaceID == "x" && flat.markAsUnreadTimestamp == 1_791_000_000_000_499)
        let thread = try Dynamite_SetTopicUnreadTimestampRequest(serializedBytes: try #require(Self.markUnreadRequests(exchange, "set_topic_unread_timestamp").first))
        #expect(thread.topicID.topicID == "t1" && thread.topicID.groupID.spaceID.spaceID == "x" && thread.unreadTimestamp == 1_791_000_000_000_499)
    }
}

@MainActor struct MarkUnreadFromMessageTests {
    @Test func theConversationStaysUnreadWhileOpenUntilLeftAndReturnedTo() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { true }
        await store.start()
        await store.select("general")
        let message = try #require(store.messages.first { $0.conversationID == "general" && $0.threadID == nil })
        let readBefore = await fake.markedRead.count
        await store.markUnread(from: message)
        #expect((store.conversations.first { $0.id == "general" }?.unread ?? 0) > 0)
        store.apply(.messageUpserted(Message(id: "g-new", conversationID: "general", sender: Person(id: "maria", name: "Maria Chen"), text: "new")))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fake.markedRead.count == readBefore)   // not read again while it stays open
        await store.select("design"); await store.select("general")
        #expect(await fake.markedRead.last == "general")
    }
}
