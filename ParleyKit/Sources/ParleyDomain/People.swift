import Foundation

/// The live value is `ChatStore.presence`; `Person.presence` is only the demo's and launch caches' copy.
public enum Presence: String, Codable, Sendable {
    case available, away, offline, doNotDisturb
    /// Its name, as Google Chat writes it beside a person and in the status menu.
    public var title: String {
        switch self {
        case .available: "Active"
        case .away: "Away"
        case .doNotDisturb: "Do not disturb"
        case .offline: "Offline"
        }
    }
}
/// My own status, as Google Chat's status menu sets it: automatic, away or Do Not Disturb (the server keeps only one),
/// and a custom status beside it.
public struct OwnStatus: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case automatic, away
        case doNotDisturb(until: Date)
    }
    public var availability: Availability = .automatic
    public var custom: CustomStatus?
    public init(availability: Availability = .automatic, custom: CustomStatus? = nil) {
        self.availability = availability
        self.custom = custom
    }
    /// Without a DND or custom status whose end has passed, before the server says it is over.
    public func current(at now: Date) -> OwnStatus {
        var status = self
        if case .doNotDisturb(let until) = availability, until <= now { status.availability = .automatic }
        if let expires = custom?.expires, expires <= now { status.custom = nil }
        return status
    }
}
/// Recurring quiet periods that turn Do not disturb on by themselves, as Google Chat keeps them for the account.
public struct DndSchedules: Equatable, Sendable {
    public struct Period: Equatable, Sendable {
        public var days: [Int]  // 1 Monday … 7 Sunday
        public var start: Int  // minutes after midnight
        public var end: Int  // before `start`: the period ends the next day; equal to it: all day
        public var enabled = true
        public var isAllDay: Bool { start == end }
        public init(days: [Int], start: Int, end: Int, enabled: Bool = true) {
            self.days = days
            self.start = start
            self.end = end
            self.enabled = enabled
        }
        /// "Sun, Mon, Tue", in the week's order where it starts, or "Every day".
        public func dayList(calendar: Calendar = .current) -> String {
            guard Set(days).count < 7 else { return "Every day" }
            let symbols = calendar.shortWeekdaySymbols  // Sunday first
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }  // indexes into `symbols`
            return order.filter { days.contains($0 == 0 ? 7 : $0) }.map { symbols[$0] }.joined(separator: ", ")
        }
    }
    public var periods: [Period] = []
    public var followsTimeZone = true  // the periods move with the Mac's time zone
    public var timeZone = TimeZone.current.identifier
    public init(periods: [Period] = [], followsTimeZone: Bool = true, timeZone: String = TimeZone.current.identifier) {
        self.periods = periods
        self.followsTimeZone = followsTimeZone
        self.timeZone = timeZone
    }
    public static let limit = 7  // as Google Chat allows
}
public struct CustomStatus: Equatable, Sendable {
    public var text: String
    public var emoji: String
    public var expires: Date?
    public init(text: String, emoji: String, expires: Date? = nil) {
        self.text = text
        self.emoji = emoji
        self.expires = expires
    }
}
/// Google Chat's "Clear status after" choices.
public enum CustomStatusExpiry: String, CaseIterable, Identifiable {
    case thirtyMinutes = "30 minutes"
    case oneHour = "1 hour"
    case fourHours = "4 hours"
    case today = "Today"
    case thisWeek = "This week"
    public var id: Self { self }
    /// Today ends at the next midnight; the week at Monday's (Sunday night), whatever the locale's first weekday.
    public func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .thirtyMinutes: now.addingTimeInterval(30 * 60)
        case .oneHour: now.addingTimeInterval(3600)
        case .fourHours: now.addingTimeInterval(4 * 3600)
        case .today: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .thisWeek:
            calendar.nextDate(
                after: now, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: 2),
                matchingPolicy: .nextTime)
        }
    }
}
/// What a person's card shows beyond their name and email; nil where they share nothing.
public struct PersonCardDetails: Equatable, Sendable {
    public var title: String?
    public var timeZone: TimeZone?
    public init(title: String? = nil, timeZone: TimeZone? = nil) {
        self.title = title
        self.timeZone = timeZone
    }
}
/// What a person's detailed view shows beyond their card, as Google Chat's does, from Google Contacts; an empty part is
/// a section it leaves out.
public struct PersonDetails: Equatable, Sendable {
    /// Someone in their reporting line.
    public struct Colleague: Identifiable, Hashable, Sendable {
        public let id: PersonID
        public var name: String
        public var avatarURL: URL?
        public var title: String?
        public init(id: PersonID, name: String, avatarURL: URL? = nil, title: String? = nil) {
            self.id = id
            self.name = name
            self.avatarURL = avatarURL
            self.title = title
        }
    }
    /// A Calendar event or Gmail thread we share, or a Drive file they shared with me: opens in the browser.
    public struct Item: Hashable, Sendable {
        public enum Kind: Sendable { case event, email, file }
        public var kind: Kind
        public var title: String
        public var url: URL
        public var date: Date?
        public init(kind: Kind, title: String, url: URL, date: Date? = nil) {
            self.kind = kind
            self.title = title
            self.url = url
            self.date = date
        }
    }
    public var reports: [Colleague] = []
    public var reportCount = 0  // can be more than `reports` lists
    public var managers: [Colleague] = []  // the management chain, as Google lists it
    public var recent: [Item] = []
    public var files: [Item] = []
    public var moreFiles: URL?  // Drive's search for everything they shared
    public init(
        reports: [Colleague] = [], reportCount: Int = 0, managers: [Colleague] = [], recent: [Item] = [],
        files: [Item] = [],
        moreFiles: URL? = nil
    ) {
        self.reports = reports
        self.reportCount = reportCount
        self.managers = managers
        self.recent = recent
        self.files = files
        self.moreFiles = moreFiles
    }
}
public struct Person: Identifiable, Hashable, Codable, Sendable {
    /// @all in a space's @ list: a mention of everyone, sent as Google Chat's MENTION_ALL.
    public static let everyone = Person(id: TextStyleRange.everyone, name: "all")
    public let id: PersonID
    public var name: String
    public var presence: Presence = .offline
    public var avatarURL: URL?  // public FIFE photo
    public var email: String?
    public var organization: Organization?  // nil if unknown
    public init(
        id: PersonID, name: String, presence: Presence = .offline, avatarURL: URL? = nil, email: String? = nil,
        organization: Organization? = nil
    ) {
        self.id = id
        self.name = name
        self.presence = presence
        self.avatarURL = avatarURL
        self.email = email
        self.organization = organization
    }
}
/// Whose account a person's is, as Google Chat states it: a personal account, or a Workspace customer's (by its id).
public enum Organization: Hashable, Sendable {
    case consumer
    case customer(String)
}
/// Stored as "consumer" or "customer:<id>", the launch cache's format from before this type.
extension Organization: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "consumer" {
            self = .consumer
        } else if raw.hasPrefix("customer:") {
            self = .customer(String(raw.dropFirst(9)))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown organization \(raw)")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .consumer: try container.encode("consumer")
        case .customer(let id): try container.encode("customer:" + id)
        }
    }
}
extension Person {
    /// Someone known only by an email address: `ChatBackend.directMessage` invites them by email.
    public static func invite(email: String) -> Person {
        Person(id: PersonID("email:" + email), name: email, email: email)
    }
    public static func invitedEmail(_ id: PersonID) -> String? {
        id.rawValue.hasPrefix("email:") ? String(id.rawValue.dropFirst(6)) : nil
    }
}
