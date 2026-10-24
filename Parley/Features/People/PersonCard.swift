import ParleyDomain
import SwiftUI

/// The header of a sender's menu, and of a member's card in the Info panel: photo, name, job title, email, and the
/// person's local time from their calendar, as Google Chat's card shows them.
struct PersonCard: View {
    let person: Person
    /// Their job title and calendar time zone, asked when the card shows; nil: neither line.
    var details: (() async -> PersonCardDetails)?
    /// The card's laid-out size, again whenever the title or local time arrives, for a host that sizes itself to the
    /// card (a menu item). Measured by SwiftUI after layout: a size read when the answer lands misses the new lines.
    var resized: (CGSize) -> Void = { _ in }
    @State private var found = PersonCardDetails()
    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: person.name, size: 36, url: person.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.headline)
                if let title = found.title { Text(title).font(.subheadline) }
                if let email = person.email {
                    Label(email, systemImage: "envelope").font(.caption).foregroundStyle(.secondary)
                }
                if let zone = found.timeZone { LocalTimeLabel(zone: zone, name: person.name).font(.caption) }
            }
        }.padding(.horizontal, 14).padding(.vertical, 6).frame(minWidth: 220, alignment: .leading)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                resized($0)
            }
            .task(id: person.id) {
                if let details { found = await details() }
            }
    }
    /// "3:04 PM local time (GMT+1)": the time where they are, with its offset, as Google Chat writes it.
    static func localTime(_ date: Date, in zone: TimeZone, locale: Locale = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        time.timeZone = zone
        var offset = Date.FormatStyle(locale: locale).timeZone(.localizedGMT(.short))
        offset.timeZone = zone
        return "\(date.formatted(time)) local time (\(date.formatted(offset)))"
    }
}

/// A person's local time, updated each minute, as Google Chat's card shows it; tagged as coming from their calendar.
struct LocalTimeLabel: View {
    let zone: TimeZone
    let name: String
    var body: some View {
        SwiftUI.TimelineView(.everyMinute) { context in
            Label(PersonCard.localTime(context.date, in: zone), systemImage: "clock").foregroundStyle(.secondary)
        }.help("From \(name)’s calendar")
    }
}
