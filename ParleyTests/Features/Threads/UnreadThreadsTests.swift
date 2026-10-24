import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// A space whose only unread items are followed threads shows bold in the sidebar, as Google Chat's web does.
struct UnreadThreadsMappingTests {
    @Test func theCountComesWithTheConversationList() {
        let item = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "S"
            $0.readState.unreadSubscribedTopicCount = 2
        }
        #expect(DynamiteMapper.conversation(item, selfID: "me", people: [:])?.unreadThreads == 2)
    }
    @Test func theCountIsPushedWhenItChanges() async throws {
        let (backend, _) = try await NetworkTests.connected()
        await backend.handle(
            .with {
                $0.event.bodies = [
                    .with {
                        $0.eventType = .groupUnreadSubscribedTopicCountUpdated
                        $0.groupUnreadSubscribedTopicCountUpdated.groupID.spaceID.spaceID = "x"
                        $0.groupUnreadSubscribedTopicCountUpdated.unreadSubscribedTopicCount = 3
                    }
                ]
            })
        #expect(await NetworkTests.drain(backend).contains(.unreadThreadsChanged("space/x", 3)))
    }
}

@MainActor struct UnreadThreadsStoreTests {
    @Test func voiceOverSaysSo() {
        let room = Conversation(id: "s", name: "Design", kind: .space, members: [], unreadThreads: 2)
        #expect(ChatView.spoken(room) == "Design, 2 unread threads")
    }
    @Test func aPushedCountUpdatesTheConversation() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.rooms.conversations.first { $0.kind == .space })
        store.apply(.unreadThreadsChanged(room.id, 3))
        #expect(store.rooms.conversations.first { $0.id == room.id }?.unreadThreads == 3)
    }
}
