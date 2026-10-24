import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// What a person's card adds to their name: their job title from Google Contacts, and the local time from the time zone
/// they share in Google Calendar.
@MainActor struct PersonCardDetailsTests {
    @Test func theStoreAsksForTitleAndTimeZoneButNeverForMe() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        #expect(
            await store.cardDetails(of: FakeBackend.directoryPerson.with(email: "sam@example.com"))
                == PersonCardDetails(title: "Product Designer", timeZone: TimeZone(identifier: "Europe/Lisbon")))
        #expect(await store.cardDetails(of: Person(id: "x", name: "No Email")) == PersonCardDetails())
        #expect(await store.cardDetails(of: store.me.with(email: "me@example.com")) == PersonCardDetails())
    }
    @Test func itReadsAsTheTimeThereWithItsOffset() throws {
        let date = try Date("2026-01-15T12:00:00Z", strategy: .iso8601)
        let line = PersonCard.localTime(
            date, in: try #require(TimeZone(identifier: "Asia/Kolkata")), locale: Locale(identifier: "en_US"))
        #expect(line.replacingOccurrences(of: "\u{202F}", with: " ") == "5:30 PM local time (GMT+5:30)")
    }
}

extension Person {
    fileprivate func with(email: String) -> Person {
        var person = self
        person.email = email
        return person
    }
}
