import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Google's services beyond Chat's own API, signed as Google Chat's web signs them: the session's cookies, a SAPISID hash
/// and the Chat page's API key; one request type per capability.
extension NetworkTests { @Suite struct GoogleServicesTests: NetworkSuite {} }

extension NetworkTests.GoogleServicesTests {
    static let googleBlock =
        #"["dfe.cr.rr",["r"],[null,[null,"/punctual/prod-dynamite-prod-02-us/user-targeted-changes",[]],[1,0],[3600],"U","web-key"],1]"#
    static func googleSignedIn(_ replies: [StubExchange.Reply]) throws -> (GoogleServices, StubExchange) {
        let sapisid = SessionCookie(
            name: "SAPISID", value: "sap", domain: ".google.com", path: "/", secure: true, expires: -1)
        let bootstrap = StubExchange.Reply(data: Data((#"{"SMqcke":"test-xsrf"} "# + googleBlock).utf8))
        let (auth, exchange) = try signedIn(replies, bootstrap: bootstrap, vault: storedSession([.testSID, sapisid]))
        return (GoogleServices(authorizer: auth), exchange)
    }

    /// Recent Drive files for "@" alone (mode 2), matches for a query (mode 4), as the @ list's Files section asks
    /// taskassist-pa; the request is signed with the hash and the page's key, and carries no Chat XSRF token.
    @Test func driveSuggestionsAreSignedAndRead() async throws {
        let reply =
            #")]}'"# + "\n"
            + #"[null,null,null,null,null,null,null,null,null,null,null,null,null,[[[["f1","Plan","application/vnd.google-apps.document"],["f2","notes.md","text/markdown"]]]]]"#
        let (google, exchange) = try Self.googleSignedIn([.init(data: Data(reply.utf8))])
        let files = try await google.send(DriveSuggestions(query: "pl"))
        #expect(
            files == [
                DriveFile(id: "f1", title: "Plan", mimeType: "application/vnd.google-apps.document"),
                DriveFile(id: "f2", title: "notes.md", mimeType: "text/markdown"),
            ])
        let sent = try #require(exchange.requests.last)
        #expect(sent.url?.host() == "taskassist-pa.clients6.google.com" && sent.url?.path == "/v2/taskassist:compose")
        #expect(
            URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
                == "web-key")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        #expect(
            sent.value(forHTTPHeaderField: "X-Goog-AuthUser") == "0"
                && sent.value(forHTTPHeaderField: "X-Framework-XSRF-Token") == nil)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json+protobuf")
        let body = try #require(try JSONSerialization.jsonObject(with: Self.body(sent)) as? [Any])
        #expect(body.first as? String == "pl" && body[2] as? Int == 4)
        #expect(DriveSuggestions(query: "").fields[2] as? Int == 2)  // "@" alone: recent files
    }
    /// Directory people for the @ list, as Google Chat's web asks People autocomplete: the key in a header (a gRPC-web
    /// service), the query in field 1. Only "PERSON" results are read; a space's result is skipped.
    @Test func directoryPeopleAreAskedWithTheKeyInAHeader() async throws {
        let person =
            #"["pat@example.com",null,"PERSON",["123",null,[[null,"Pat Doe"]],[[null,"https://example.invalid/pat.jpg"]]]]"#
        let group = #"[null,null,"AUTOCOMPLETE_GROUP",{"11":["space/s"]}]"#
        let reply = "[[\(person),\(group),[\"x@example.com\",null,\"PERSON\",[\"\",null,[]]]]]"
        let (google, exchange) = try Self.googleSignedIn([.init(data: Data(reply.utf8))])
        let people = try await google.send(PeopleAutocomplete(query: "pa"))
        #expect(
            people == [
                Person(
                    id: "123", name: "Pat Doe", avatarURL: URL(string: "https://example.invalid/pat.jpg"),
                    email: "pat@example.com")
            ])
        let sent = try #require(exchange.requests.last)
        #expect(sent.url?.host() == "people-pa.clients6.google.com" && sent.url?.query() == nil)
        #expect(
            sent.value(forHTTPHeaderField: "x-goog-api-key") == "web-key"
                && sent.value(forHTTPHeaderField: "x-user-agent") == "grpc-web-javascript/0.1")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: Self.body(sent)) as? [Any])
        #expect(body.first as? String == "pa" && (body[3] as? [String]) == ["DYNAMITE_WEB"])
    }
    /// A person's calendar time zone for their card's local time, as Google Chat asks People Stack: feature 1 by email,
    /// the key in a header; the reply's zone is read from field 2.
    @Test func aPersonsTimeZoneIsAskedByEmail() async throws {
        let reply =
            #"["7",[[[null,"1"],[1,"pat@example.com"],[[[[[1,0],[2,0]],[null,[]],[null,null,["Asia/Kolkata"]]]],[3,0],[]]]]]"#
        let (google, exchange) = try Self.googleSignedIn([.init(data: Data(reply.utf8))])
        #expect(try await google.send(PersonTimeZone(email: "pat@example.com")) == TimeZone(identifier: "Asia/Kolkata"))
        let sent = try #require(exchange.requests.last)
        #expect(
            sent.url?.host() == "peoplestack-pa.clients6.google.com"
                && sent.url?.path.hasSuffix("/GetAssistiveFeatures") == true)
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "web-key" && sent.url?.query() == nil)
        let body = try #require(String(data: Self.body(sent), encoding: .utf8))
        #expect(body == #"[[1,"1"],[[[[1,"pat@example.com"]],[1]]]]"#)
        #expect(try PersonTimeZone(email: "x").reply(Data(#"["7"]"#.utf8)) == nil)  // shares none
    }
    static let contactsPage =
        #"<script>window.WIZ_global_data = {"FdrFJe":"-42","SNlM0e":"tok:1","cfb2h":"contacts_build"};</script>"#
    static func contactsSignedIn(_ replies: [StubExchange.Reply]) throws -> (GoogleContacts, StubExchange) {
        let (auth, exchange) = try signedIn(replies)
        return (GoogleContacts(authorizer: auth), exchange)
    }
    /// A batch answer as Google sends it: the guard, then length-prefixed lines, the call's result as a JSON string.
    static func batchReply(_ rpc: String, _ result: Any) throws -> StubExchange.Reply {
        let inner = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        let entry = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                ["wrb.fr", rpc, inner, NSNull(), NSNull(), NSNull(), "generic"]
            ]), as: UTF8.self)
        return .init(data: Data(")]}'\n\n\(entry.utf8.count)\n\(entry)\n25\n[[\"e\",4,null,null,123]]\n".utf8))
    }
    static func form(_ request: URLRequest) -> [String: String] {
        Dictionary(
            String(decoding: body(request), as: UTF8.self).split(separator: "&").compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }, uniquingKeysWith: { $1 })
    }
    /// A person's job title, as Google Chat's card asks Google Contacts: the widget page is read once for its token,
    /// session id and build, then the card call goes in a batch with that token, the cookies and no Chat XSRF token.
    @Test func aJobTitleIsAskedFromTheContactsWidget() async throws {
        let person: [Any] =
            [["Pat Doe", 1], NSNull(), "123", "123"] + Array(repeating: NSNull(), count: 11) + [
                ["Product Designer", NSNull(), 3]
            ]
        let (contacts, exchange) = try Self.contactsSignedIn([
            .init(data: Data(Self.contactsPage.utf8)), try Self.batchReply("wiDBGd", [1, person]),
        ])
        #expect(try await contacts.send(ContactCard(email: "pat@example.com", name: "Pat & Co")) == "Product Designer")
        let page = try #require(exchange.requests.dropFirst().first)
        #expect(
            page.url == GoogleContacts.pageURL
                && page.value(forHTTPHeaderField: "Cookie")?.contains("SID=test-session") == true)
        let sent = try #require(exchange.requests.last)
        #expect(sent.url?.host() == "contacts.google.com" && sent.url?.path == "/_/PeopleCompanionUi/data/batchexecute")
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map
            { ($0.name, $0.value ?? "") })
        #expect(query["rpcids"] == "wiDBGd" && query["f.sid"] == "-42" && query["bl"] == "contacts_build")
        #expect(
            sent.value(forHTTPHeaderField: "X-Same-Domain") == "1"
                && sent.value(forHTTPHeaderField: "X-Framework-XSRF-Token") == nil)
        let form = Self.form(sent)
        #expect(form["at"] == "tok:1")
        let request = try #require(form["f.req"])
        let batch = try #require(try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [[[Any]]])
        #expect(batch[0][0][0] as? String == "wiDBGd")
        let argumentText = try #require(batch[0][0][1] as? String)
        let arguments = try #require(try JSONSerialization.jsonObject(with: Data(argumentText.utf8)) as? [Any])
        #expect(arguments[3] as? [String] == ["Pat & Co", "pat@example.com"])  // "&" stays in the name
        #expect(try ContactCard(email: "x", name: "x").reply([1, [["X", 1]]]) == nil)  // no title
    }
    /// A refused call, or an answer without the call's result, reads the widget page again for a new token and retries once.
    @Test func aRefusedContactsCallReadsThePageAgain() async throws {
        let newPage = Self.contactsPage.replacingOccurrences(of: "tok:1", with: "tok:2")
        let person: [Any] = [["Pat Doe", 1]] + Array(repeating: NSNull(), count: 14) + [["CEO"]]
        let (contacts, exchange) = try Self.contactsSignedIn([
            .init(data: Data(Self.contactsPage.utf8)), .init(status: 400),
            .init(data: Data(newPage.utf8)), try Self.batchReply("wiDBGd", [1, person]),
        ])
        #expect(try await contacts.send(ContactCard(email: "pat@example.com", name: "Pat")) == "CEO")
        #expect(Self.form(try #require(exchange.requests.last))["at"] == "tok:2")
    }
    /// Only Chat decides the session: Google Contacts sending its sign-in page refuses that call, and Parley stays signed in.
    @Test func anotherServicesSignInPageKeepsTheSession() async throws {
        let toAccounts = ["Location": "https://accounts.google.com/ServiceLogin"]
        let vault = try Self.storedSession()
        let (auth, _) = try Self.signedIn(
            [.init(status: 302, headers: toAccounts), .init(status: 302, headers: toAccounts)], vault: vault)
        let contacts = GoogleContacts(authorizer: auth)
        await #expect(throws: (any Error).self) {
            try await contacts.send(ContactCard(email: "pat@example.com", name: "Pat"))
        }
        #expect(try vault.read() != nil)
    }
    /// Only Google's own service hosts get signed requests; anything else is refused before it's sent.
    @Test func onlyKnownHostsAreSigned() throws {
        #expect(throws: AuthFailure.self) {
            try WebSessionAuthorizer.validateDestination(URL(string: "https://evil.example/x"))
        }
        #expect(throws: AuthFailure.self) {
            try WebSessionAuthorizer.validateDestination(URL(string: "https://other-pa.clients6.google.com/x"))
        }
        for host in GoogleHost.allCases {
            try WebSessionAuthorizer.validateDestination(URL(string: "https://\(host.rawValue)/x"))
        }
        try WebSessionAuthorizer.validateDestination(GoogleContacts.pageURL)
    }
    /// JSPB: field n is at index n-1, after Google's ")]}'" guard.
    @Test func jspbReadsFieldsByNumber() throws {
        let value = try JSPB.parse(Data(")]}'\n[\"a\",null,[7]]".utf8))
        #expect(
            JSPB.field(value, 1) as? String == "a" && JSPB.field(value, 2) == nil
                && JSPB.field(JSPB.field(value, 3), 1) as? Int == 7)
    }
}

extension NetworkTests.GoogleServicesTests {
    /// The @ list's Apps section: the conversation's own apps (autocomplete_bots, members-only filter 3).
    @Test func appsComeFromAutocompleteBotsForTheSpacesOwnApps() async throws {
        let reply = Dynamite_AutocompleteBotsResponse.with {
            $0.bots = [
                .with {
                    $0.userID.id = "b1"
                    $0.userID.type = .bot
                    $0.name = "Poll"
                }
            ]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(reply)])
        #expect(try await backend.searchApps(in: "space/s1", matching: "po").map(\.id) == ["b1"])
        let sent = try Dynamite_AutocompleteBotsRequest(
            serializedBytes: Self.body(
                try #require(exchange.requests.last { $0.url?.path == "/api/autocomplete_bots" })))
        #expect(
            sent.query == "po" && sent.appFilters == [3] && sent.maxResults == 4 && sent.groupID.spaceID.spaceID == "s1"
                && sent.hasRequestHeader)
    }
}
