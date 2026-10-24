import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Events Google Chat pushes beyond messages and read state: topics, settings, history, blocks, counts.
@MainActor struct PushedEventsStoreTests {
    @Test func aScheduleFromElsewhereReplacesTheOneShownAndActivityOnlyMovesForward() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let schedules = DndSchedules(
            periods: [.init(days: [1], start: 60, end: 120, enabled: false)], followsTimeZone: true, timeZone: "UTC")
        store.apply(.dndSchedulesChanged(schedules))
        #expect(store.dndSchedules == schedules)
        let room = try #require(store.rooms.conversations.first)
        let later = (room.activity ?? .now).addingTimeInterval(60)
        store.apply(.conversationActivity(room.id, at: later))
        #expect(store.rooms.conversations.first { $0.id == room.id }?.activity == later)
        store.apply(.conversationActivity(room.id, at: .distantPast))
        #expect(store.rooms.conversations.first { $0.id == room.id }?.activity == later)
    }
    /// History cleared on another device: the messages up to the clear time are gone here too.
    @Test func clearedHistoryRemovesOlderMessages() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("maria")
        let held = store.history.messages.filter { $0.conversationID == "maria" }.sorted { $0.createdAt < $1.createdAt }
        #expect(held.count >= 2)
        let cut = held[held.count - 2].createdAt
        store.apply(.historyCleared("maria", upTo: cut))
        #expect(store.history.messages.filter { $0.conversationID == "maria" }.map(\.id) == [held.last!.id])
    }
    /// Google asks Home's lists to be read again: Home's threads come back from the server.
    @Test func aHomeRefreshReadsHomesThreadsAgain() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await fake.setHomeThreads([])
        store.apply(.homeRefreshed)
        await eventually { store.rooms.homeThreads.isEmpty }
        #expect(store.rooms.homeThreads.isEmpty)
    }
}

struct PushedEventsTests {
    private static func topic(_ id: String, replies: [Dynamite_Message], space: String = "x") -> Dynamite_Topic {
        .with {
            $0.id.topicID = id
            $0.id.groupID.spaceID.spaceID = space
            $0.replies = replies
        }
    }
    private static func event(_ body: Dynamite_EventBody) -> Dynamite_StreamEventsResponse {
        .with { $0.event.bodies = [body] }
    }

    /// An Ask Gemini session's topic comes whole: its messages show as if each were posted.
    @Test func anUpdatedTopicBringsItsMessages() async throws {
        let (backend, _) = try await NetworkTests.connected()
        let replies = [
            NetworkTests.message("s1", topic: "s1", at: 1_000_000),
            NetworkTests.message("s1r", topic: "s1", at: 2_000_000, by: "u1"),
        ]
        await backend.handle(
            Self.event(
                .with {
                    $0.eventType = .topicUpdated
                    $0.topicUpdated.topic = Self.topic("s1", replies: replies)
                }))
        let ids = NetworkTests.upserts(await NetworkTests.drain(backend)).map(\.id)
        #expect(ids.contains("space/x/s1/s1") && ids.contains("space/x/s1/s1r"))
    }
    /// A schedule changed elsewhere comes whole; a conversation's sort time moves with its activity.
    @Test func aScheduleAndASortTimeBecomeEvents() async throws {
        let (backend, _) = try await NetworkTests.connected()
        await backend.handle(
            Self.event(
                .with {
                    $0.eventType = .userRecurringDndUpdatedEvent
                    $0.recurringDndUpdated.recurringDnd = .with { dnd in
                        dnd.schedules = [
                            .with {
                                $0.days = [6, 7]
                                $0.start = 0
                                $0.end = 1440
                                $0.enabled = true
                            }
                        ]
                        dnd.timeZone = "Europe/Madrid"
                    }
                }))
        await backend.handle(
            Self.event(
                .with {
                    $0.eventType = .groupDefaultSortOrderUpdated
                    $0.groupDefaultSortOrderUpdated.groupID.spaceID.spaceID = "x"
                    $0.groupDefaultSortOrderUpdated.defaultSortTime = 5_000_000
                }))
        let events = await NetworkTests.drain(backend)
        #expect(
            events.contains(
                .dndSchedulesChanged(
                    DndSchedules(
                        periods: [.init(days: [6, 7], start: 0, end: 1440, enabled: true)],
                        followsTimeZone: false, timeZone: "Europe/Madrid"))))
        #expect(events.contains(.conversationActivity("space/x", at: Date(timeIntervalSince1970: 5))))
    }
    @Test func historyHomeAndBlocksBecomeEvents() async throws {
        let (backend, _) = try await NetworkTests.connected()
        await backend.handle(
            Self.event(
                .with {
                    $0.eventType = .clearHistory
                    $0.historyCleared.groupID.dmID.dmID = "d"
                    $0.historyCleared.clearedUpTo = 7_000_000
                }))
        await backend.handle(Self.event(.with { $0.eventType = .worldRefreshed }))
        await backend.handle(Self.event(.with { $0.eventType = .blockStateChanged }))
        let events = await NetworkTests.drain(backend)
        #expect(events.contains(.historyCleared("dm/d", upTo: Date(timeIntervalSince1970: 7))))
        #expect(events.contains(.homeRefreshed))
        #expect(events.contains(.blocksChanged))
    }
    /// TOPIC_CREATED always comes with the head message's MESSAGE_POSTED, which brings the message.
    @Test func aCreatedTopicAddsNothingOfItsOwn() async throws {
        let (backend, _) = try await NetworkTests.connected()
        await backend.handle(Self.event(.with { $0.eventType = .topicCreated }))
        #expect(NetworkTests.upserts(await NetworkTests.drain(backend)).isEmpty)
    }
}
