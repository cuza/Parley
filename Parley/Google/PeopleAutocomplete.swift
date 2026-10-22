import Foundation

/// People from the organisation's directory for the @ list's People section, as Google Chat's web asks People
/// autocomplete. The reply's field 1 lists results `[email, _, kind, person]`; a "PERSON" one carries the Chat user id,
/// name and photo. An empty query gets an empty answer, so it isn't sent.
struct PeopleAutocomplete: GoogleRequest {
    let query: String
    var host: GoogleHost { .people }
    var path: String { "/$rpc/google.internal.people.v2.minimal.PeopleApiAutocompleteMinimalService/ListAutocompletions" }
    var grpcWeb: Bool { true }
    /// As web sends them; field 8's meaning isn't known.
    var body: (data: Data, contentType: String) {
        get throws { try Self.jspb([query, nil, nil, ["DYNAMITE_WEB"], 40, nil, nil, [nil, nil, [nil, 2]], ["DYNAMITE_WEB", nil, 2]]) }
    }
    func reply(_ data: Data) throws -> [Person] {
        let results = JSPB.field(try JSPB.parse(data), 1) as? [Any] ?? []
        return results.compactMap { result in
            guard let result = result as? [Any], result.count >= 4, result[2] as? String == "PERSON",
                  let person = result[3] as? [Any], let id = person.first as? String, !id.isEmpty,
                  let name = Self.first(person, 3), !name.isEmpty else { return nil }
            return Person(id: id, name: name, avatarURL: Self.first(person, 4).flatMap(URL.init(string:)), email: result[0] as? String)
        }
    }
    /// The value of the first entry of the person's field `n`: entries are `[metadata, value, …]`.
    private static func first(_ person: [Any], _ n: Int) -> String? {
        ((JSPB.field(person, n) as? [Any])?.first as? [Any]).flatMap { $0.count > 1 ? $0[1] as? String : nil }
    }
}
