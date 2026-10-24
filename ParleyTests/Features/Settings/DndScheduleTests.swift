import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Do not disturb schedules on the wire, in the layout Google Chat keeps them (made-up values).
extension NetworkTests { @Suite struct DndScheduleTests: NetworkSuite {} }

extension NetworkTests.DndScheduleTests {
    /// {2 packed days, 3 start, 4 end, 5 enabled}: 22:30 to 6:45, Monday to Thursday, switched on.
    static let weeknights = Wire.ld(2, [1, 2, 3, 4]) + Wire.int(3, 1350) + Wire.int(4, 405) + Wire.int(5, 1)
    static let weekends = Wire.ld(2, [6, 7]) + Wire.int(3, 0) + Wire.int(4, 0) + Wire.int(5, 0)

    @Test func readingAsksWithTheTimeZoneAndMapsEverySchedule() async throws {
        let reply =
            Wire.ld(
                1,
                Wire.ld(1, Self.weeknights) + Wire.ld(1, Self.weekends) + Wire.int(2, 1) + Wire.str(3, "Europe/Paris"))
            + Wire.ld(2, Wire.int(1, 1_700_000_000_000_000))  // the last update time is not used
        let (backend, exchange) = try await Self.connected([
            .init(headers: ["Content-Type": "application/x-protobuf"], data: Data(reply))
        ])
        let schedules = try await backend.dndSchedules(timeZone: "Europe/Paris")
        #expect(
            schedules
                == DndSchedules(
                    periods: [
                        .init(days: [1, 2, 3, 4], start: 1350, end: 405, enabled: true),
                        .init(days: [6, 7], start: 0, end: 0, enabled: false),
                    ],
                    followsTimeZone: true, timeZone: "Europe/Paris"))
        #expect(try Self.body(exchange, "get_recurring_dnd") == Wire.str(1, "Europe/Paris") + Wire.ld(100, Self.header))
    }
    /// set_recurring_dnd sends the whole set: {1 RecurringDnd, 2: 0, 100 header}, as Google Chat does.
    @Test func savingSendsTheWholeSet() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_SetRecurringDndResponse())])
        try await backend.setDndSchedules(
            DndSchedules(
                periods: [
                    .init(days: [1, 2, 3, 4], start: 1350, end: 405, enabled: true),
                    .init(days: [6, 7], start: 0, end: 0, enabled: false),
                ],
                followsTimeZone: true, timeZone: "Europe/Paris"))
        #expect(
            try Self.body(exchange, "set_recurring_dnd") == Wire.ld(
                1,
                Wire.ld(1, Self.weeknights) + Wire.ld(1, Self.weekends)
                    + Wire.int(2, 1) + Wire.str(3, "Europe/Paris"))
                + Wire.int(2, 0) + Wire.ld(100, Self.header))
    }
}

struct DndSchedulePeriodTests {
    @Test func aPeriodReadsAsTheWebShowsIt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        let weeknights = DndSchedules.Period(days: [1, 2, 3, 4], start: 1350, end: 405)
        #expect(weeknights.dayList(calendar: calendar) == "Mon, Tue, Wed, Thu")
        #expect(
            DndSchedules.Period(days: [1, 2, 3, 4, 5, 6, 7], start: 0, end: 0).dayList(calendar: calendar)
                == "Every day")
        #expect(DndSchedules.Period(days: [6, 7], start: 0, end: 0).isAllDay)
    }
}

/// Loading and saving from Settings, against the fake backend.
@MainActor
struct DndScheduleStoreTests {
    @Test func savingReplacesTheSetAndAFailureKeepsTheOld() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.loadDndSchedules()
        let old = try #require(store.dndSchedules)
        var new = old
        new.periods.append(.init(days: [6, 7], start: 0, end: 0))
        await store.saveDndSchedules(new)
        #expect(store.dndSchedules == new)
        #expect(await fake.dndSchedules(timeZone: "UTC").periods == new.periods)
        await fake.simulateChangeFailure()
        await store.saveDndSchedules(old)
        #expect(store.dndSchedules == new && store.error != nil)
    }
}
