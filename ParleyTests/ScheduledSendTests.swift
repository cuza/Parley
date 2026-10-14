import Foundation
import Testing
@testable import Parley

/// Scheduled messages on the wire, in the shapes Google Chat's web client sends and receives (ids made up). They are
/// unsent messages of type SCHEDULED, with the send time at field 8.
extension AuthTests {
    static let tomorrow = Date(timeIntervalSince1970: 1_791_979_200)
    static func scheduledMessage(state: UInt64 = 1) -> [UInt8] {
        Wire.ld(1, unsentID("sChEd000a1")) + Wire.str(4, "See you at the review") + Wire.int(7, 1)
            + Wire.ld(8, Wire.ld(1, Wire.int(1, 1_791_979_200)) + Wire.int(2, state)) + Wire.str(9, "")
    }

    /// create_unsent_message: {1 header, 2 UnsentMessage {1 id, 4 text, 7 SCHEDULED, 8 {1 Timestamp {1 seconds}}, 9 ""}}.
    @Test func schedulingCreatesAScheduledUnsentMessage() async throws {
        let created = Dynamite_CreateUnsentMessageResponse.with { $0.unsentMessage = try! .init(serializedBytes: Self.scheduledMessage()) }
        let (backend, exchange) = try await Self.connected([try Self.proto(created)])
        let saved = try await backend.saveDraft(ServerDraft(conversationID: "space/AAQAexample", text: "See you at the review",
                                                            schedule: .init(at: Self.tomorrow)))
        #expect(saved.id.count == 11 && saved.schedule == .init(at: Self.tomorrow))
        #expect(try Self.body(exchange, "create_unsent_message") == Wire.ld(1, Self.header)
                + Wire.ld(2, Wire.ld(1, Self.unsentID(saved.id)) + Wire.str(4, "See you at the review") + Wire.int(7, 1)
                          + Wire.ld(8, Wire.ld(1, Wire.int(1, 1_791_979_200))) + Wire.str(9, "")))
    }
    /// update_unsent_message with only the id and the new time, and the mask {1: [{1: 8, 2: {2: [1]}}]}: field 8, its field 1.
    @Test func reschedulingSendsOnlyTheNewTime() async throws {
        let later = Date(timeIntervalSince1970: 1_791_997_200)
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateUnsentMessageResponse())])
        let message = ServerDraft(id: "sChEd000a1", conversationID: "space/AAQAexample", text: "See you at the review", schedule: .init(at: Self.tomorrow))
        let moved = try await backend.reschedule(message, to: later)
        #expect(moved.schedule?.at == later && moved.text == "See you at the review")
        #expect(try Self.body(exchange, "update_unsent_message") == Wire.ld(1, Self.header)
                + Wire.ld(2, Wire.ld(1, Self.unsentID("sChEd000a1")) + Wire.ld(8, Wire.ld(1, Wire.int(1, 1_791_997_200))))
                + Wire.ld(3, Wire.ld(1, Wire.int(1, 8) + Wire.ld(2, Wire.ld(2, [1])))))
    }
    /// list_unsent_messages as Google Chat's start-up asks for scheduled messages: filter {3 SCHEDULED, 5 1}.
    @Test func listingAsksForScheduledMessagesAndMapsTheirTimes() async throws {
        let reply = StubExchange.Reply(headers: ["Content-Type": "application/x-protobuf"],
                                       data: Data(Wire.ld(1, Self.scheduledMessage()) + Wire.ld(1, Self.scheduledMessage(state: 2))))
        let (backend, exchange) = try await Self.connected([reply])
        let list = try await backend.scheduled()
        #expect(list.map(\.schedule) == [.init(at: Self.tomorrow), .init(at: Self.tomorrow, failed: true)])
        #expect(list.first?.text == "See you at the review" && list.first?.conversationID == "space/AAQAexample")
        #expect(try Self.body(exchange, "list_unsent_messages") == Wire.ld(1, Self.header) + Wire.ld(2, []) + Wire.ld(3, Wire.int(3, 1) + Wire.int(5, 1)))
    }
    @Test func aPushedScheduledMessageCarriesItsTime() throws {
        let draft = try #require(DynamiteMapper.draft(try Dynamite_UnsentMessage(serializedBytes: Self.scheduledMessage())))
        #expect(draft.schedule == .init(at: Self.tomorrow) && draft.id == "sChEd000a1")
    }
}

/// Scheduling from the composer, and the scheduled list, against the fake backend.
@MainActor
struct ScheduledSendStoreTests {
    static let alex = "alex/timeline"
    private func started() async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        await fake.simulateDrafts([]); await fake.simulateScheduled([])
        let store = ChatStore(backend: fake)
        store.draftPause = .milliseconds(30); store.draftIdle = .seconds(5)
        await store.start()
        return (store, fake)
    }
    private static let tomorrow = Date.now.addingTimeInterval(86_400)

    @Test func schedulingTakesTheComposersTextAndListsIt() async throws {
        let (store, fake) = await started()
        store.setDraft("see you then", conversation: "alex", thread: nil)
        #expect(store.canSchedule(conversation: "alex", thread: nil))
        await store.schedule(conversation: "alex", thread: nil, at: Self.tomorrow)
        #expect(store.drafts[Self.alex, default: ""].isEmpty)
        #expect(store.scheduled.map(\.text) == ["see you then"] && store.scheduled.first?.schedule?.at == Self.tomorrow)
        let server = await fake.scheduledMessages
        #expect(server.map(\.text) == ["see you then"])
        #expect(store.scheduled(in: "alex", thread: nil).count == 1 && store.scheduled(in: "maria", thread: nil).isEmpty)
    }
    @Test func filesAQuoteOrAnEditCannotBeScheduled() async throws {
        let (store, _) = await started()
        #expect(!store.canSchedule(conversation: "alex", thread: nil))   // nothing to send
        store.setDraft("hi", conversation: "alex", thread: nil)
        store.editing[Self.alex] = "m1"
        #expect(!store.canSchedule(conversation: "alex", thread: nil))
    }
    @Test func sendNowSendsItNamingTheScheduledMessage() async throws {
        let (store, fake) = await started()
        store.setDraft("now please", conversation: "alex", thread: nil)
        await store.schedule(conversation: "alex", thread: nil, at: Self.tomorrow)
        let scheduled = try #require(store.scheduled.first)
        await store.sendNow(scheduled)
        let server = await fake.scheduledMessages
        #expect(store.scheduled.isEmpty && server.isEmpty)   // the send names it, and the server drops it
        #expect(store.messages.contains { $0.conversationID == "alex" && $0.text == "now please" })
    }
    @Test func rescheduleAndDeleteChangeTheList() async throws {
        let (store, fake) = await started()
        store.setDraft("later", conversation: "alex", thread: nil)
        await store.schedule(conversation: "alex", thread: nil, at: Self.tomorrow)
        let later = Self.tomorrow.addingTimeInterval(3_600)
        await store.reschedule(try #require(store.scheduled.first), to: later)
        let moved = await fake.scheduledMessages
        #expect(store.scheduled.first?.schedule?.at == later && moved.first?.schedule?.at == later)
        await store.unschedule(try #require(store.scheduled.first))
        let left = await fake.scheduledMessages
        #expect(store.scheduled.isEmpty && left.isEmpty)
    }
    @Test func pushedScheduledMessagesStayOutOfTheComposer() async throws {
        let (store, _) = await started()
        store.apply(.draftChanged(ServerDraft(id: "w1", conversationID: "alex", text: "from the web", schedule: .init(at: Self.tomorrow))))
        #expect(store.drafts[Self.alex] == nil && store.scheduled.map(\.id) == ["w1"])
        store.apply(.draftDeleted("w1"))   // sent at its time, or deleted elsewhere
        #expect(store.scheduled.isEmpty)
    }
    @Test func startListsScheduledMessages() async throws {
        let fake = FakeBackend()
        await fake.simulateScheduled([ServerDraft(id: "s1", conversationID: "launch", text: "Standup notes", schedule: .init(at: Self.tomorrow))])
        let store = ChatStore(backend: fake)
        await store.start()
        #expect(store.scheduled.map(\.id) == ["s1"])
    }
    /// Web's choices: tomorrow at 8:00 and at 13:00, and next Monday at 8:00.
    @Test func theQuickTimesAreWebs() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let wednesday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 30)))
        let times = ScheduledSend.quickTimes(from: wednesday, calendar: calendar).map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0) }
        #expect(times == [DateComponents(month: 10, day: 15, hour: 8, minute: 0), DateComponents(month: 10, day: 15, hour: 13, minute: 0),
                          DateComponents(month: 10, day: 19, hour: 8, minute: 0)])
    }
}
