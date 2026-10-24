import Foundation

/// A person's time zone from their Google Calendar, which Google Chat's person card shows as their local time: People
/// Stack's GetAssistiveFeatures, feature 1, keyed by email. The reply's field 2 carries the IANA zone name inside a
/// validity window; nil when the person shares none.
struct PersonTimeZone: GoogleRequest {
    let email: String
    var host: GoogleHost { .peopleStack }
    var path: String {
        "/$rpc/social.people.backend.service.intelligence.proto.PeopleStackIntelligenceService/GetAssistiveFeatures"
    }
    var grpcWeb: Bool { true }
    /// `[[client 1, "1"], [[[[1 (an email), email]], [feature 1]]]]`, as the Chat page sends it.
    var body: (data: Data, contentType: String) { get throws { try Self.jspb([[1, "1"], [[[[1, email]], [1]]]]) } }
    func reply(_ data: Data) throws -> TimeZone? {
        // The zone sits a few arrays deep: the first string under field 2 that names a time zone.
        func zone(_ node: Any?) -> TimeZone? {
            if let name = node as? String { return name.contains("/") ? TimeZone(identifier: name) : nil }
            return (node as? [Any])?.lazy.compactMap(zone).first
        }
        return zone(JSPB.field(try JSPB.parse(data), 2))
    }
}
