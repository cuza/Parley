import Foundation
import ParleyDomain

/// Who is around and what they are doing: typing, availability, custom status, read receipts and apps at work. Fed by
/// realtime events through `ChatStore`; times come in as arguments, so the store's clock (which tests replace) drives it.
@MainActor @Observable final class PresenceModel {
    /// An app at work in a composer (Ask Gemini's "Collecting info"), shown in its typing line.
    struct Activity: Equatable {
        var person: PersonID
        var label: String
        var at: Date
    }

    static let typingTimeout: TimeInterval = 8, typingInterval: TimeInterval = 5, presenceTTL: TimeInterval = 60
    /// How long an app's activity line stays without a repeat; an agent repeats its status every few seconds.
    static let activityTimeout: TimeInterval = 15

    var typing: [String: [PersonID: Date]] = [:]  // draft key → typist → local arrival
    var activities: [String: Activity] = [:]  // draft key → the app at work there
    var availability: [PersonID: Presence] = [:]
    var customStatus: [PersonID: String] = [:]
    var readReceipts: [ConversationID: [PersonID: Date]] = [:]  // reader → read up to
    /// Conversations whose readers turned receipts off for me; their receipts aren't asked for.
    @ObservationIgnored var receiptsOff: Set<ConversationID> = []
    @ObservationIgnored var fetched: [PersonID: Date] = [:]  // when each person's availability was last asked for
    @ObservationIgnored var typingSent: [String: Date] = [:]  // draft key → when I last said I was typing there
    @ObservationIgnored var typingRefused: Set<String> = []  // composers where Google answered 403; not retried this session
    @ObservationIgnored var watching: Set<ConversationID>?  // conversations whose typing the realtime channel watches

    /// A message or event from `person` shows they're here, unless they set Do not disturb.
    func markActive(_ person: PersonID, at time: Date) {
        if availability[person] != .doNotDisturb { availability[person] = .available }
        fetched[person] = time
    }
    /// Typists whose last "typing" arrived more than 8 s ago are gone. Google Chat times from the server's start time,
    /// which a fast Mac clock would expire on arrival, so this uses the local arrival time.
    func sweepTyping(at time: Date) {
        let cutoff = time.addingTimeInterval(-Self.typingTimeout)
        activities = activities.filter { $0.value.at > time.addingTimeInterval(-Self.activityTimeout) }
        for (scope, people) in typing where people.values.contains(where: { $0 <= cutoff }) {
            let kept = people.filter { $0.value > cutoff }
            typing[scope] = kept.isEmpty ? nil : kept
        }
    }
    func typists(in scope: String) -> [PersonID] { (typing[scope] ?? [:]).keys.sorted() }
    /// Whether to tell Google I'm typing in `scope` now: at most every 5 s, and never where Google refused it.
    func shouldSendTyping(in scope: String, at time: Date) -> Bool {
        guard !typingRefused.contains(scope) else { return false }
        if let last = typingSent[scope], time.timeIntervalSince(last) < Self.typingInterval { return false }
        return true
    }
    /// Of `people`, those whose availability is over a minute old or never asked for.
    func stale(_ people: Set<PersonID>, at time: Date) -> Set<PersonID> {
        people.filter { id in fetched[id].map { time.timeIntervalSince($0) >= Self.presenceTTL } ?? true }
    }
    /// Everyone whose receipt covers a message sent at `time` in `conversation`, for "Seen by …".
    func readers(in conversation: ConversationID, upTo time: Date) -> [PersonID] {
        (readReceipts[conversation] ?? [:]).filter { $0.value >= time }.keys.sorted()
    }
    /// "Ana is typing…", "Ana and Ben are typing…", up to three first names, then "Several people are typing…".
    static func typingLine(_ names: [String]) -> String? {
        let first = names.map { String($0.split(separator: " ").first ?? Substring($0)) }
        switch first.count {
        case 0: return nil
        case 1: return "\(first[0]) is typing…"
        case 2, 3: return "\(ListFormatter.localizedString(byJoining: first)) are typing…"
        default: return "Several people are typing…"
        }
    }
}
