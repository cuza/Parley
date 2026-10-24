import Foundation
import SwiftProtobuf
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// My own status (Do Not Disturb, away, custom status) through the backend, network-stubbed, in the shapes Google Chat
/// sends and answers them.
extension NetworkTests { @Suite struct OwnStatusTests: NetworkSuite {} }

extension NetworkTests.OwnStatusTests {
    private static func saved(_ fill: (inout Dynamite_UserStatus) -> Void) throws -> StubExchange.Reply {
        try proto(
            Dynamite_SetUserStatusResponse.with {
                $0.userStatus.userID.id = "me"
                fill(&$0.userStatus)
            })
    }

    /// set_dnd_duration: {1 duration µs, 100 header}; the answer's DND expiry is µs.
    @Test func doNotDisturbSendsTheDurationAndReadsTheExpiry() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.saved {
                $0.dndSettings.dndState = .dnd
                $0.dndSettings.dndExpiryTimeUsec = 1_800_000_000_000_000
                $0.presenceShared = true
            }
        ])
        let status = try await backend.setDoNotDisturb(for: 30 * 60)
        #expect(try Self.body(exchange, "set_dnd_duration") == Wire.int(1, 1_800_000_000) + Wire.ld(100, Self.header))
        #expect(status == OwnStatus(availability: .doNotDisturb(until: Date(timeIntervalSince1970: 1_800_000_000))))
    }
    /// set_presence_shared: {1 bool, 100 header}; false is away, true automatic (which also ends DND on the server).
    @Test func awayAndAutomaticSendPresenceShared() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.saved {
                $0.dndSettings.dndState = .available
                $0.presenceShared = false
            },
            try Self.saved {
                $0.dndSettings.dndState = .available
                $0.presenceShared = true
            },
        ])
        #expect(try await backend.setAway(true) == OwnStatus(availability: .away))
        let away = try Self.body(exchange, "set_presence_shared")
        #expect(try await backend.setAway(false) == OwnStatus(availability: .automatic))
        #expect(away == Wire.int(1, 0) + Wire.ld(100, Self.header))
        #expect(try Self.body(exchange, "set_presence_shared") == Wire.int(1, 1) + Wire.ld(100, Self.header))
    }
    /// set_custom_status: {1 CustomStatus {1 text, 4 Emoji {1 unicode}}, 2 absolute expiry µs, 100 header}.
    @Test func customStatusSendsTextEmojiAndExpiry() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.saved {
                $0.presenceShared = true
                $0.customStatus = .with {
                    $0.statusText = "Lunch"
                    $0.emoji.unicode = "🥪"
                    $0.stateExpiryTimestampUsec = 1_800_000_000_000_000
                }
            }
        ])
        let lunch = CustomStatus(text: "Lunch", emoji: "🥪", expires: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try await backend.setCustomStatus(lunch) == OwnStatus(custom: lunch))
        #expect(
            try Self.body(exchange, "set_custom_status")
                == Wire.ld(1, Wire.str(1, "Lunch") + Wire.ld(4, Wire.str(1, "🥪"))) + Wire.int(2, 1_800_000_000_000_000)
                + Wire.ld(100, Self.header))
    }
    /// Clearing is {3: 0} with no status, as Google Chat's "Clear custom status" sends it.
    @Test func clearingTheCustomStatusSendsAZeroDuration() async throws {
        let (backend, exchange) = try await Self.connected([try Self.saved { $0.presenceShared = true }])
        #expect(try await backend.setCustomStatus(nil) == OwnStatus())
        #expect(try Self.body(exchange, "set_custom_status") == Wire.int(3, 0) + Wire.ld(100, Self.header))
    }
    /// Connecting reads my status; a USER_STATUS_UPDATED_EVENT about me (a change made elsewhere) updates it.
    @Test func connectAndPushesReportMyStatus() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(
            .with {
                $0.event.bodies = [
                    .with { body in
                        body.eventType = .userStatusUpdatedEvent
                        body.userStatusUpdated.userStatus = .with {
                            $0.userID.id = "me"
                            $0.presenceShared = false
                            $0.dndSettings.dndState = .available
                            $0.customStatus = .with {
                                $0.statusText = "Out sick"
                                $0.emoji.unicode = "🤒"
                            }
                        }
                    }
                ]
            })
        let events = await Self.drain(backend).filter { if case .ownStatusChanged = $0 { true } else { false } }
        #expect(
            events == [
                .ownStatusChanged(OwnStatus()),
                .ownStatusChanged(
                    OwnStatus(availability: .away, custom: CustomStatus(text: "Out sick", emoji: "🤒", expires: nil))),
            ])
    }
}

@MainActor struct OwnStatusStoreTests {
    @Test func theStoreKeepsWhatTheServerSavedAndWhatItPushes() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { false }
        await store.start()
        await store.setDoNotDisturb(for: 3600)
        guard case .doNotDisturb = store.ownStatus.availability else {
            Issue.record("not DND: \(store.ownStatus)")
            return
        }
        await store.setAway(false)
        #expect(store.ownStatus.availability == .automatic)
        let lunch = CustomStatus(text: "Lunch", emoji: "🥪", expires: .now.addingTimeInterval(3600))
        await store.setCustomStatus(lunch)
        #expect(store.ownStatus.custom == lunch)
        #expect(await fake.ownStatus.custom == lunch)
        store.apply(.ownStatusChanged(OwnStatus(availability: .away)))  // changed on another device
        #expect(store.ownStatus == OwnStatus(availability: .away))
    }
    /// A DND or custom status past its expiry shows as over, before the server says so.
    @Test func expiredParts() {
        let at = Date(timeIntervalSince1970: 1000)
        let status = OwnStatus(
            availability: .doNotDisturb(until: at), custom: CustomStatus(text: "x", emoji: "💭", expires: at))
        #expect(status.current(at: at.addingTimeInterval(-1)) == status)
        #expect(status.current(at: at) == OwnStatus())
        let away = OwnStatus(availability: .away, custom: CustomStatus(text: "x", emoji: "💭", expires: nil))
        #expect(away.current(at: at) == away)
    }
    /// Google Chat's "Clear status after" choices: fixed spans, the next midnight, and Monday's midnight (the week ends
    /// on Sunday night whatever the locale's first weekday).
    @Test func expiryChoicesEndWhereGoogleChatsDo() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar.firstWeekday = 1  // Sunday, as in the US
        let day = { (dayOfMonth: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: dayOfMonth)) }
        let saturday = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 50)))
        #expect(
            CustomStatusExpiry.thirtyMinutes.date(from: saturday, calendar: calendar)
                == saturday.addingTimeInterval(1800))
        #expect(
            CustomStatusExpiry.fourHours.date(from: saturday, calendar: calendar)
                == saturday.addingTimeInterval(4 * 3600))
        #expect(CustomStatusExpiry.today.date(from: saturday, calendar: calendar) == day(11))
        #expect(CustomStatusExpiry.thisWeek.date(from: saturday, calendar: calendar) == day(12))
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8)))
        #expect(CustomStatusExpiry.thisWeek.date(from: monday, calendar: calendar) == day(19))
    }
}
