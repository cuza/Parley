import Foundation
import Testing

@testable import Parley
@testable import ParleyData

/// Reads and unread marks made on another device (or the web), as Google Chat pushes them to every session.
struct ReadElsewhereBackendTests {
    private static func topic(_ id: String) -> Dynamite_TopicId {
        .with {
            $0.topicID = id
            $0.groupID.spaceID.spaceID = "x"
        }
    }
    @Test func pushedViewsAndUnreadMarksBecomeReadEvents() async throws {
        let (backend, _) = try await NetworkTests.connected()
        await backend.handle(
            .with {
                $0.event.bodies = [
                    .with {
                        $0.eventType = .topicViewed
                        $0.topicViewed.topicID = Self.topic("t1")
                        $0.topicViewed.viewTime = 2_000_000
                    },
                    .with {
                        $0.eventType = .groupViewed
                        $0.groupViewed.groupID.spaceID.spaceID = "x"
                        $0.groupViewed.viewTime = 3_000_000
                    },
                    .with {
                        $0.eventType = .markTopicAsUnreadUpdated
                        $0.markTopicAsUnreadUpdated.topicID = Self.topic("t2")
                        $0.markTopicAsUnreadUpdated.markTime = 4
                    },
                    .with {
                        $0.eventType = .markTopicAsUnreadUpdated
                        $0.markTopicAsUnreadUpdated.topicID = Self.topic("t3")
                    },
                    .with {
                        $0.eventType = .markAsUnread
                        $0.markAsUnread.groupID.spaceID.spaceID = "y"
                        $0.markAsUnread.markTime = 5
                    },
                ]
            })
        let events = await NetworkTests.drain(backend)
        #expect(events.contains(.threadViewed("space/x/t1/t1", at: Date(timeIntervalSince1970: 2))))
        #expect(events.contains(.conversationViewed("space/x", at: Date(timeIntervalSince1970: 3))))
        #expect(events.contains(.threadMarkedUnread("space/x/t2/t2", true)))
        #expect(events.contains(.threadMarkedUnread("space/x/t3/t3", false)))
        #expect(events.contains(.conversationMarkedUnread("space/y")))
    }
    /// Opening a conversation marked unread on the web only clears the mark (its read time doesn't move): it is read
    /// again if it was read past its newest message, and stays unread if a newer message came.
    @Test func aClearedUnreadMarkReadsTheConversationOnlyIfReadPastItsNewest() async throws {
        let (backend, _) = try await NetworkTests.connected()
        func viewed(_ time: Int64) -> Dynamite_StreamEventsResponse {
            .with {
                $0.event.bodies = [
                    .with {
                        $0.eventType = .groupViewed
                        $0.groupViewed.groupID.spaceID.spaceID = "x"
                        $0.groupViewed.viewTime = time
                    }
                ]
            }
        }
        let cleared = Dynamite_StreamEventsResponse.with {
            $0.event.bodies = [
                .with {
                    $0.eventType = .markAsUnread
                    $0.markAsUnread.groupID.spaceID.spaceID = "x"
                }
            ]
        }
        await backend.handle(
            NetworkTests.pushed(.messagePosted, NetworkTests.message("h1", topic: "h1", at: 2_000_000)))
        await backend.handle(viewed(3_000_000))
        await backend.handle(cleared)
        await backend.handle(
            NetworkTests.pushed(.messagePosted, NetworkTests.message("h2", topic: "h2", at: 4_000_000)))
        await backend.handle(cleared)
        let events = await NetworkTests.drain(backend)
        #expect(events.filter { $0 == .readStateChanged("space/x", unread: 0) }.count == 1)
    }
    @Test func aThreadMarkedUnreadLoadsUnread() {
        let topic = Dynamite_Topic.with {
            $0.id.topicID = "t1"
            $0.id.groupID.spaceID.spaceID = "x"
            $0.sortTime = 3_000_000
            $0.replies = [
                NetworkTests.message("t1", topic: "t1", at: 1_000, by: "u1"),
                NetworkTests.message("r1", topic: "t1", at: 3_000_000, by: "u1"),
            ]
            $0.topicReadState.lastReadTime = 3_000_000
            $0.topicReadState.markAsUnreadTime = 3_500_000
        }
        #expect(DynamiteMapper.homeThread(topic, selfID: "me", people: [:])?.unread == true)
    }
}

@MainActor struct ReadElsewhereStoreTests {
    @Test func aThreadReadElsewhereStopsCounting() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let thread = try #require(store.rooms.homeThreads.first { $0.unread })
        store.apply(.threadViewed(thread.id, at: thread.latest.createdAt.addingTimeInterval(-1)))  // before its newest reply
        #expect(store.unreadThreadCount == 1)
        store.apply(.threadViewed(thread.id, at: thread.latest.createdAt))
        #expect(store.unreadThreadCount == 0)
        store.apply(.threadMarkedUnread(thread.id, true))
        #expect(store.unreadThreadCount == 1)
        store.apply(.threadMarkedUnread(thread.id, false))
        #expect(store.unreadThreadCount == 0)
    }
    @Test func aConversationMarkedUnreadElsewhereCounts() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.rooms.conversations.first { $0.unread == 0 && !$0.muted })
        let before = store.badgeCount
        store.apply(.conversationMarkedUnread(room.id))
        #expect(store.rooms.conversations.first { $0.id == room.id }?.unread == 1 && store.badgeCount == before + 1)
    }
    @Test func aConversationReadElsewhereStopsCounting() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.rooms.conversations.first { $0.unread > 0 && !$0.muted })
        store.apply(.conversationViewed(room.id, at: .distantPast))  // an older read leaves newer messages unread
        #expect(store.rooms.conversations.first { $0.id == room.id }?.unread == room.unread)
        store.apply(.conversationViewed(room.id, at: .now.addingTimeInterval(60)))
        #expect(store.rooms.conversations.first { $0.id == room.id }?.unread == 0)
    }
    /// A reaction or edit moves a conversation's activity later than its newest message; a read of that message is still a read.
    @Test func aReadOfTheNewestMessageClearsAfterLaterActivity() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("alex")
        store.isAppActive = { false }
        let newest = try #require(
            store.history.messages.filter { $0.conversationID == "alex" && $0.threadID == nil }.map(\.createdAt).max())
        store.apply(.conversationMarkedUnread("alex"))
        var room = try #require(store.rooms.conversations.first { $0.id == "alex" })
        room.activity = newest.addingTimeInterval(30)
        store.apply(.conversationUpserted(room))
        store.apply(.conversationViewed("alex", at: newest))
        #expect(store.rooms.conversations.first { $0.id == "alex" }?.unread == 0)
    }
}
