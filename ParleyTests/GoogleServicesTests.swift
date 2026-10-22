import Foundation
import Testing
@testable import Parley

/// Google's services beyond Chat's own API, signed as Google Chat's web signs them: the session's cookies, a SAPISID hash
/// and the Chat page's API key; one request type per capability.
/// Network-stubbed: joins the serialized AuthTests suite, which shares AuthStubProtocol's registry.
extension AuthTests {
    static let googleBlock = #"["dfe.cr.rr",["r"],[null,[null,"/punctual/prod-dynamite-prod-02-us/user-targeted-changes",[]],[1,0],[3600],"U","web-key"],1]"#
    static func googleSignedIn(_ replies: [StubExchange.Reply]) throws -> (GoogleServices, StubExchange) {
        let vault = MemoryVault()
        let cookies = [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1),
                       SessionCookie(name: "SAPISID", value: "sap", domain: ".google.com", path: "/", secure: true, expires: -1)]
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "T")))
        let bootstrap = StubExchange.Reply(data: Data((#"{"SMqcke":"test-xsrf"} "# + googleBlock).utf8))
        let exchange = StubExchange([bootstrap] + replies)
        return (GoogleServices(authorizer: WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))), exchange)
    }

    /// Recent Drive files for "@" alone (mode 2), matches for a query (mode 4), as the @ list's Files section asks
    /// taskassist-pa; the request is signed with the hash and the page's key, and carries no Chat XSRF token.
    @Test func driveSuggestionsAreSignedAndRead() async throws {
        let reply = #")]}'"# + "\n" + #"[null,null,null,null,null,null,null,null,null,null,null,null,null,[[[["f1","Plan","application/vnd.google-apps.document"],["f2","notes.md","text/markdown"]]]]]"#
        let (google, exchange) = try Self.googleSignedIn([.init(data: Data(reply.utf8))])
        let files = try await google.send(DriveSuggestions(query: "pl"))
        #expect(files == [DriveFile(id: "f1", title: "Plan", mimeType: "application/vnd.google-apps.document"),
                          DriveFile(id: "f2", title: "notes.md", mimeType: "text/markdown")])
        let sent = try #require(exchange.requests.last)
        #expect(sent.url?.host() == "taskassist-pa.clients6.google.com" && sent.url?.path == "/v2/taskassist:compose")
        #expect(URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value == "web-key")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        #expect(sent.value(forHTTPHeaderField: "X-Goog-AuthUser") == "0" && sent.value(forHTTPHeaderField: "X-Framework-XSRF-Token") == nil)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json+protobuf")
        let body = try #require(try JSONSerialization.jsonObject(with: Self.body(sent)) as? [Any])
        #expect(body.first as? String == "pl" && body[2] as? Int == 4)
        #expect(DriveSuggestions(query: "").fields[2] as? Int == 2)   // "@" alone: recent files
    }
    /// Directory people for the @ list, as Google Chat's web asks People autocomplete: the key in a header (a gRPC-web
    /// service), the query in field 1. Only "PERSON" results are read; a space's result is skipped.
    @Test func directoryPeopleAreAskedWithTheKeyInAHeader() async throws {
        let person = #"["pat@example.com",null,"PERSON",["123",null,[[null,"Pat Doe"]],[[null,"https://example.invalid/pat.jpg"]]]]"#
        let group = #"[null,null,"AUTOCOMPLETE_GROUP",{"11":["space/s"]}]"#
        let reply = "[[\(person),\(group),[\"x@example.com\",null,\"PERSON\",[\"\",null,[]]]]]"
        let (google, exchange) = try Self.googleSignedIn([.init(data: Data(reply.utf8))])
        let people = try await google.send(PeopleAutocomplete(query: "pa"))
        #expect(people == [Person(id: "123", name: "Pat Doe", avatarURL: URL(string: "https://example.invalid/pat.jpg"), email: "pat@example.com")])
        let sent = try #require(exchange.requests.last)
        #expect(sent.url?.host() == "people-pa.clients6.google.com" && sent.url?.query() == nil)
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "web-key" && sent.value(forHTTPHeaderField: "x-user-agent") == "grpc-web-javascript/0.1")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: Self.body(sent)) as? [Any])
        #expect(body.first as? String == "pa" && (body[3] as? [String]) == ["DYNAMITE_WEB"])
    }
    /// A person's calendar time zone for their card's local time, as Google Chat asks People Stack: feature 1 by email,
    /// the key in a header; the reply's zone is read from field 2.
    @Test func aPersonsTimeZoneIsAskedByEmail() async throws {
        let reply = #"["7",[[[null,"1"],[1,"pat@example.com"],[[[[[1,0],[2,0]],[null,[]],[null,null,["Asia/Kolkata"]]]],[3,0],[]]]]]"#
        let (google, exchange) = try Self.googleSignedIn([.init(data: Data(reply.utf8))])
        #expect(try await google.send(PersonTimeZone(email: "pat@example.com")) == TimeZone(identifier: "Asia/Kolkata"))
        let sent = try #require(exchange.requests.last)
        #expect(sent.url?.host() == "peoplestack-pa.clients6.google.com" && sent.url?.path.hasSuffix("/GetAssistiveFeatures") == true)
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "web-key" && sent.url?.query() == nil)
        let body = try #require(String(data: Self.body(sent), encoding: .utf8))
        #expect(body == #"[[1,"1"],[[[[1,"pat@example.com"]],[1]]]]"#)
        #expect(try PersonTimeZone(email: "x").reply(Data(#"["7"]"#.utf8)) == nil)   // shares none
    }
    static let contactsPage = #"<script>window.WIZ_global_data = {"FdrFJe":"-42","SNlM0e":"tok:1","cfb2h":"contacts_build"};</script>"#
    static func contactsSignedIn(_ replies: [StubExchange.Reply]) throws -> (GoogleContacts, StubExchange) {
        let vault = MemoryVault()
        let cookies = [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1)]
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "T")))
        let exchange = StubExchange([StubExchange.Reply(data: Data(#"{"SMqcke":"test-xsrf"}"#.utf8))] + replies)
        return (GoogleContacts(authorizer: WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))), exchange)
    }
    /// A batch answer as Google sends it: the guard, then length-prefixed lines, the call's result as a JSON string.
    static func batchReply(_ rpc: String, _ result: Any) throws -> StubExchange.Reply {
        let inner = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        let entry = String(decoding: try JSONSerialization.data(withJSONObject: [["wrb.fr", rpc, inner, NSNull(), NSNull(), NSNull(), "generic"]]), as: UTF8.self)
        return .init(data: Data(")]}'\n\n\(entry.utf8.count)\n\(entry)\n25\n[[\"e\",4,null,null,123]]\n".utf8))
    }
    static func form(_ request: URLRequest) -> [String: String] {
        Dictionary(String(decoding: body(request), as: UTF8.self).split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { $1 })
    }
    /// A person's job title, as Google Chat's card asks Google Contacts: the widget page is read once for its token,
    /// session id and build, then the card call goes in a batch with that token, the cookies and no Chat XSRF token.
    @Test func aJobTitleIsAskedFromTheContactsWidget() async throws {
        let person: [Any] = [["Pat Doe", 1], NSNull(), "123", "123"] + Array(repeating: NSNull(), count: 11) + [["Product Designer", NSNull(), 3]]
        let (contacts, exchange) = try Self.contactsSignedIn([.init(data: Data(Self.contactsPage.utf8)), try Self.batchReply("wiDBGd", [1, person])])
        #expect(try await contacts.send(ContactCard(email: "pat@example.com", name: "Pat & Co")) == "Product Designer")
        let page = try #require(exchange.requests.dropFirst().first)
        #expect(page.url == GoogleContacts.pageURL && page.value(forHTTPHeaderField: "Cookie")?.contains("SID=s") == true)
        let sent = try #require(exchange.requests.last)
        #expect(sent.url?.host() == "contacts.google.com" && sent.url?.path == "/_/PeopleCompanionUi/data/batchexecute")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["rpcids"] == "wiDBGd" && query["f.sid"] == "-42" && query["bl"] == "contacts_build")
        #expect(sent.value(forHTTPHeaderField: "X-Same-Domain") == "1" && sent.value(forHTTPHeaderField: "X-Framework-XSRF-Token") == nil)
        let form = Self.form(sent)
        #expect(form["at"] == "tok:1")
        let request = try #require(form["f.req"])
        let batch = try #require(try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [[[Any]]])
        #expect(batch[0][0][0] as? String == "wiDBGd")
        let argumentText = try #require(batch[0][0][1] as? String)
        let arguments = try #require(try JSONSerialization.jsonObject(with: Data(argumentText.utf8)) as? [Any])
        #expect(arguments[3] as? [String] == ["Pat & Co", "pat@example.com"])   // "&" stays in the name
        #expect(try ContactCard(email: "x", name: "x").reply([1, [["X", 1]]]) == nil)   // no title
    }
    /// A refused call, or an answer without the call's result, reads the widget page again for a new token and retries once.
    @Test func aRefusedContactsCallReadsThePageAgain() async throws {
        let newPage = Self.contactsPage.replacingOccurrences(of: "tok:1", with: "tok:2")
        let person: [Any] = [["Pat Doe", 1]] + Array(repeating: NSNull(), count: 14) + [["CEO"]]
        let (contacts, exchange) = try Self.contactsSignedIn([.init(data: Data(Self.contactsPage.utf8)), .init(status: 400),
                                                              .init(data: Data(newPage.utf8)), try Self.batchReply("wiDBGd", [1, person])])
        #expect(try await contacts.send(ContactCard(email: "pat@example.com", name: "Pat")) == "CEO")
        #expect(Self.form(try #require(exchange.requests.last))["at"] == "tok:2")
    }
    /// Only Chat decides the session: Google Contacts sending its sign-in page refuses that call, and Parley stays signed in.
    @Test func anotherServicesSignInPageKeepsTheSession() async throws {
        let toAccounts = ["Location": "https://accounts.google.com/ServiceLogin"]
        let vault = MemoryVault()
        let cookies = [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1)]
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "T")))
        let exchange = StubExchange([.init(data: Data(#"{"SMqcke":"test-xsrf"}"#.utf8)), .init(status: 302, headers: toAccounts),
                                     .init(status: 302, headers: toAccounts)])
        let contacts = GoogleContacts(authorizer: WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange)))
        await #expect(throws: (any Error).self) { try await contacts.send(ContactCard(email: "pat@example.com", name: "Pat")) }
        #expect(try vault.read() != nil)
    }
    /// Only Google's own service hosts get signed requests; anything else is refused before it's sent.
    @Test func onlyKnownHostsAreSigned() throws {
        #expect(throws: AuthFailure.self) { try WebSessionAuthorizer.validateDestination(URL(string: "https://evil.example/x")) }
        #expect(throws: AuthFailure.self) { try WebSessionAuthorizer.validateDestination(URL(string: "https://other-pa.clients6.google.com/x")) }
        for host in GoogleHost.allCases { try WebSessionAuthorizer.validateDestination(URL(string: "https://\(host.rawValue)/x")) }
        try WebSessionAuthorizer.validateDestination(GoogleContacts.pageURL)
    }
    /// JSPB: field n is at index n-1, after Google's ")]}'" guard.
    @Test func jspbReadsFieldsByNumber() throws {
        let value = try JSPB.parse(Data(")]}'\n[\"a\",null,[7]]".utf8))
        #expect(JSPB.field(value, 1) as? String == "a" && JSPB.field(value, 2) == nil && JSPB.field(JSPB.field(value, 3), 1) as? Int == 7)
    }
}

/// A Drive file picked from the @ list: offered in its own section, put in as its title, and sent as Google Chat's web
/// sends it.
@MainActor struct DriveChipTests {
    static let plan = DriveFile(id: "f1", title: "Plan", mimeType: "application/vnd.google-apps.document")
    /// DRIVE_FILE over the title, render-if-possible, inline; metadata {1 id, 2 title, 9 false, 12 {}, 14 type}; and the
    /// message says it needs Drive chips (feature 4), as the server records.
    @Test func aDriveChipIsSentAsGoogleChatSendsIt() throws {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .drive(Self.plan), start: 4, length: 4)])
        let chip = try #require(sent.first { $0.type == .driveFile })
        #expect(chip.startIndex == 4 && chip.length == 4 && chip.chipRenderType == .renderIfPossible && chip.inlineRenderFormat == 1)
        #expect(chip.driveMetadata.id == "f1" && chip.driveMetadata.title == "Plan" && chip.driveMetadata.mimeType == Self.plan.mimeType)
        #expect(chip.driveMetadata.hasField9 && !chip.driveMetadata.field9 && chip.driveMetadata.hasField12)
        #expect(sent.first { $0.type == .requiredMessageFeaturesMetadata }?.requiredMessageFeaturesMetadata.requiredFeatures == [4])
    }
    /// The @ list's Files section, after people and spaces: files the server found for the query. Picking one puts its
    /// title in as a chip and a space after it.
    @Test func theAtListOffersFilesAndPickingOneMakesItsChip() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var asked: [String] = []
        view.needMentionResults = { asked.append($0) }
        view.load("", [])
        view.insertText("see @pl", replacementRange: view.selectedRange())
        #expect(asked.last == "pl")
        view.driveFiles = Found(query: "pl", items: [Self.plan])
        #expect(view.mentionMatches == [.file(Self.plan)])
        view.insert(.file(Self.plan), replacing: try #require(view.mentionQuery?.range))
        #expect(view.string == "see Plan ")
        #expect(view.formatting == [TextStyleRange(style: .drive(Self.plan), start: 4, length: 4)])
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())   // edited inside: plain text again
        #expect(view.formatting.isEmpty)
    }
    @Test func theStoreAsksForFilesAndKeepsTheLatest() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.searchMentionResults("design", "road")
        await eventually { !store.driveFiles.items.isEmpty }
        #expect(store.driveFiles == Found(query: "road", items: [FakeBackend.driveFiles[0]]))
    }
    /// Google matches a file's contents too: the answer for the query shows as is, though no title contains it. While
    /// the answer for a newer query is on its way, the last one is narrowed to titles that contain it.
    @Test func filesShowAsTheServerFoundThem() {
        let notes = DriveFile(id: "f2", title: "notes.md", mimeType: "text/markdown")
        let found = Found(query: "w", items: [notes, Self.plan])
        #expect(MentionQuery.filter(files: found, by: "w") == [notes, Self.plan])
        #expect(MentionQuery.filter(files: found, by: "wp").isEmpty)
        #expect(MentionQuery.filter(files: Found(query: "p", items: [notes, Self.plan]), by: "pl") == [Self.plan])
    }
}

/// The @ list in sections, as Google Chat shows it: People, then Files, then Spaces, each under its name.
@MainActor struct MentionSectionTests {
    @Test func sectionsAreNamedAndOrderedAsGoogleChatShowsThem() {
        let person = Suggestion.person(Person(id: "p", name: "Pat")), file = Suggestion.file(DriveChipTests.plan)
        let room = Suggestion.room(Conversation(id: "space/s", name: "Plans", kind: .space, members: []))
        #expect(MentionList.headers([person, file, room]) == [0: "People", 1: "Files", 2: "Spaces"])
        #expect(MentionList.headers([person, .person(Person(id: "q", name: "Quinn"))]) == [0: "People"])
        #expect(MentionList.headers([.emoji(CustomEmoji(id: "e", shortcode: "e"))]).isEmpty)   // a :shortcode list has none
        // The popup grows by a header's height for each, up to 8 rows' worth, then scrolls.
        #expect(MentionPopup.height(rows: 3, headers: 3) == 3 * MentionList.rowHeight + 3 * MentionList.headerHeight + 8)
        #expect(MentionPopup.height(rows: 20, headers: 3) == 8 * MentionList.rowHeight + 8)
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.mentionPeople = [Person(id: "p", name: "Plato")]
        view.chipConversations = [Conversation(id: "space/s", name: "Plans", kind: .space, members: [])]
        view.load("", [])
        view.insertText("@pl", replacementRange: view.selectedRange())
        view.driveFiles = Found(query: "pl", items: [DriveChipTests.plan])
        #expect(view.mentionMatches.map(\.id) == ["p:p", "f:f1", "r:space/s"])
    }
    /// People beyond the members come from the directory, after the members who match, as Google Chat lists them; a
    /// member the directory also finds shows once.
    @Test func directoryPeopleFollowTheMembers() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        let plato = Person(id: "p", name: "Plato"), wu = Person(id: "w", name: "Wu Pell")
        view.mentionPeople = [plato]
        view.load("", [])
        view.insertText("@p", replacementRange: view.selectedRange())
        view.directoryPeople = Found(query: "p", items: [wu, plato])
        #expect(view.mentionMatches.map(\.id) == ["p:p", "p:w"])
        #expect(MentionList.headers(view.mentionMatches) == [0: "People"])
    }
    @Test func theStoreAsksTheDirectoryButNotForItself() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.searchMentionResults("design", "sa")
        await eventually { !store.directoryPeople.items.isEmpty }
        #expect(store.directoryPeople == Found(query: "sa", items: [FakeBackend.directoryPerson]))
    }
}

/// The @ list's Apps section: the conversation's own apps, as autocomplete_bots finds them with the members-only filter
/// (3), so mentioning one never adds an app. A mention of an app goes out as a bot's.
@MainActor struct AppMentionTests {
    static let poll = Person(id: "b1", name: "Poll")
    @Test func anAppsMentionIsABotsMentionBothWays() throws {
        let sent = try #require(DynamiteMapper.annotations([TextStyleRange(style: .appMention(userID: "b1"), start: 0, length: 5)]).first)
        #expect(sent.userMentionMetadata.id.id == "b1" && sent.userMentionMetadata.id.type == .bot && sent.userMentionMetadata.type == .mention)
        var message = Dynamite_Message.with { $0.id.messageID = "m"; $0.textBody = "@Poll"; $0.creator.userID.id = "me" }
        message.annotations = [sent]
        let mapped = try #require(DynamiteMapper.message(message, in: "space/s1", selfID: "me", people: [:]))
        #expect(mapped.formatting == [TextStyleRange(style: .appMention(userID: "b1"), start: 0, length: 5)])
    }
    @Test func theAtListOffersTheSpacesAppsUnderApps() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var asked: [String] = []
        view.needMentionResults = { asked.append($0) }
        view.mentionPeople = [Person(id: "p", name: "Pat")]
        view.load("", [])
        view.insertText("@p", replacementRange: view.selectedRange())
        view.mentionApps = Found(query: "p", items: [Self.poll])
        #expect(asked.last == "p")
        #expect(view.mentionMatches.map(\.id) == ["p:p", "a:b1"])
        #expect(MentionList.headers(view.mentionMatches) == [0: "People", 1: "Apps"])
        view.insert(.app(Self.poll), replacing: try #require(view.mentionQuery?.range))
        #expect(view.string == "@Poll ")
        #expect(view.formatting == [TextStyleRange(style: .appMention(userID: "b1"), start: 0, length: 5)])
    }
}

extension AuthTests {
    /// The @ list's Apps section: the conversation's own apps (autocomplete_bots, members-only filter 3).
    @Test func appsComeFromAutocompleteBotsForTheSpacesOwnApps() async throws {
        let reply = Dynamite_AutocompleteBotsResponse.with { $0.bots = [.with { $0.userID.id = "b1"; $0.userID.type = .bot; $0.name = "Poll" }] }
        let (backend, exchange) = try await Self.connected([try Self.proto(reply)])
        #expect(try await backend.apps(in: "space/s1", matching: "po").map(\.id) == ["b1"])
        let sent = try Dynamite_AutocompleteBotsRequest(serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/autocomplete_bots" })))
        #expect(sent.query == "po" && sent.appFilters == [3] && sent.maxResults == 4 && sent.groupID.spaceID.spaceID == "s1" && sent.hasRequestHeader)
    }
}

/// A mention of someone who isn't a member, as Google Chat sends it: INVITE adds them where I may add people to a space
/// or group; REFERENCE only names them in a 1:1 DM or without that right. Undecided until the member list is known.
@MainActor struct OutsiderMentionTests {
    static let wu = TextStyleRange(style: .mention(userID: "w"), start: 0, length: 3)
    static let plato = TextStyleRange(style: .mention(userID: "p"), start: 4, length: 6)
    static let members = [Person(id: "p", name: "Plato")]
    @Test func aNonMemberIsInvitedOnlyWhereIMayAddPeople() {
        #expect(ChatStore.outsiders([Self.wu, Self.plato], members: Self.members, kind: .space, canAdd: true) == ["w": .invite])
        #expect(ChatStore.outsiders([Self.wu], members: Self.members, kind: .group, canAdd: true) == ["w": .invite])
        #expect(ChatStore.outsiders([Self.wu], members: Self.members, kind: .space, canAdd: false) == ["w": .reference])
        #expect(ChatStore.outsiders([Self.wu], members: Self.members, kind: .direct, canAdd: true) == ["w": .reference])
        #expect(ChatStore.outsiders([Self.wu], members: nil, kind: .space, canAdd: true).isEmpty)
        let all = TextStyleRange(style: .mention(userID: TextStyleRange.everyone), start: 0, length: 4)
        #expect(ChatStore.outsiders([all], members: [], kind: .space, canAdd: true).isEmpty)
    }
    @Test func theirMentionGoesAsInviteOrReference() throws {
        let sent = DynamiteMapper.annotations([Self.wu, Self.plato], outsiders: ["w": .invite])
        #expect(sent.map(\.userMentionMetadata.type) == [.invite, .mention])
        #expect(sent[0].userMentionMetadata.inviteeInfo.userID.id == "w" && sent[0].userMentionMetadata.id.type == .human)
        #expect(DynamiteMapper.annotations([Self.wu], outsiders: ["w": .reference]).first?.userMentionMetadata.type == .reference)
    }
}

/// Before a mention adds someone, Parley asks as Google Chat does ("Add to this conversation?"): Add and Send invites
/// them, Send Without Adding only names them, Cancel keeps the draft.
@MainActor struct AddPromptTests {
    static let sam = FakeBackend.directoryPerson
    private func drafted() async -> (FakeBackend, ChatStore, String) {
        let fake = FakeBackend(), store = ChatStore(backend: fake)
        await store.start()
        await store.loadMembers("design"); await store.loadPermissions("design")
        store.setDraft("@Sam Okafor hi", formatting: [TextStyleRange(style: .mention(userID: Self.sam.id), start: 0, length: 11)],
                       conversation: "design", thread: nil)
        return (fake, store, store.key("design", nil))
    }
    @Test func sendAsksFirstAndCancelKeepsTheDraft() async {
        let (fake, store, scope) = await drafted()
        await store.send(conversation: "design")
        #expect(store.addPrompts[scope] == ["Sam Okafor"])
        #expect(await fake.sentDrafts.isEmpty && store.drafts[scope] == "@Sam Okafor hi")
    }
    @Test func addAndSendInvitesThem() async throws {
        let (fake, store, scope) = await drafted()
        await store.send(conversation: "design", adding: true)
        #expect(try #require(await fake.sentDrafts.last).outsiders == [Self.sam.id: .invite])
        #expect(store.addPrompts[scope] == nil)
    }
    @Test func sendWithoutAddingOnlyNamesThem() async throws {
        let (fake, store, _) = await drafted()
        await store.send(conversation: "design", adding: false)
        #expect(try #require(await fake.sentDrafts.last).outsiders == [Self.sam.id: .reference])
    }
}

/// What a person's card adds to their name: their job title from Google Contacts, and the local time from the time zone
/// they share in Google Calendar.
@MainActor struct PersonCardDetailsTests {
    @Test func theStoreAsksForTitleAndTimeZoneButNeverForMe() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        #expect(await store.cardDetails(of: FakeBackend.directoryPerson.with(email: "sam@example.com"))
                == PersonCardDetails(title: "Product Designer", timeZone: TimeZone(identifier: "Europe/Lisbon")))
        #expect(await store.cardDetails(of: Person(id: "x", name: "No Email")) == PersonCardDetails())
        #expect(await store.cardDetails(of: store.me.with(email: "me@example.com")) == PersonCardDetails())
    }
    @Test func itReadsAsTheTimeThereWithItsOffset() throws {
        let date = try Date("2026-01-15T12:00:00Z", strategy: .iso8601)
        let line = PersonCard.localTime(date, in: try #require(TimeZone(identifier: "Asia/Kolkata")), locale: Locale(identifier: "en_US"))
        #expect(line.replacingOccurrences(of: "\u{202F}", with: " ") == "5:30 PM local time (GMT+5:30)")
    }
}

private extension Person {
    func with(email: String) -> Person { var person = self; person.email = email; return person }
}

/// A person's detailed view, as Google Chat's: their reporting line, what we recently shared and their files, each read
/// from Google Contacts' answer; opened in the side pane from their card.
@MainActor struct PersonDetailsTests {
    static let build = "contacts_build"
    @Test func reportsAndTheManagementChainAreRead() throws {
        let pat: [Any] = ["Pat Doe", "1", "https://example.invalid/pat.jpg", "Engineer"]
        let kim: [Any] = ["Kim Lee", "2", NSNull(), ""]
        let request = ContactReports(id: "9", email: nil)
        #expect(request.arguments(build: Self.build)[2] as? [String] == [])   // the id is enough
        #expect((request.arguments(build: Self.build)[0] as? [[Any]])?[0][2] as? String == Self.build)
        let top = try request.reply([[NSNull(), [pat, kim], "", 3, NSNull(), NSNull()]])
        #expect(top.reports == [.init(id: "1", name: "Pat Doe", avatarURL: URL(string: "https://example.invalid/pat.jpg"), title: "Engineer"),
                                .init(id: "2", name: "Kim Lee", avatarURL: nil, title: nil)])
        #expect(top.reportCount == 3 && top.managers.isEmpty)
        let report = try request.reply([[NSNull(), [], "", 0, NSNull(), [[pat], kim]]])
        #expect(report.reports.isEmpty && report.managers.map(\.id) == ["1"])
    }
    @Test func recentInteractionsAndFilesAreRead() throws {
        let event: [Any] = [1, "https://example.invalid/event", "Review", NSNull(), NSNull(), [1_790_000_000], [NSNull(), "Review"]]
        let mail: [Any] = [2, "https://example.invalid/mail", "Notes", NSNull(), [NSNull(), [true, false, "0"]], [1_790_000_000], [NSNull(), "Notes"]]
        let recent = try ContactRecent(id: "9", email: "pat@example.com").reply([[[event, mail, [3, "x", "Other"]]]])
        #expect(recent.map(\.kind) == [.event, .email] && recent.map(\.title) == ["Review", "Notes"])
        #expect(recent[0].date == Date(timeIntervalSince1970: 1_790_000_000))
        let file: [Any] = ["Plan", "https://example.invalid/plan", "https://example.invalid/icon", [1_790_000_000, 5]]
        let files = try ContactFiles(id: "9").reply([[file], "https://example.invalid/drive"])
        #expect(files.files == [.init(kind: .file, title: "Plan", url: URL(string: "https://example.invalid/plan")!, date: Date(timeIntervalSince1970: 1_790_000_000))])
        #expect(files.moreFiles == URL(string: "https://example.invalid/drive"))
    }
    /// Show Details puts the person over what the pane shows; ⇧⌘I from there goes back to the info panel, and opening a
    /// thread replaces them.
    @Test func detailsOpenInTheSidePane() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let maria = Person(id: "maria", name: "Maria Chen")
        store.showDetails(maria)
        #expect(store.pane(nil).person == maria && ChatView.paneShown(store.pane(nil), room: nil))
        store.toggleInfo()
        #expect(store.pane(nil).person == nil && store.pane(nil).info)
        store.showDetails(maria, window: "design")
        #expect(store.pane("design").person == maria && store.pane(nil).person == nil)
        let details = try #require(await store.personDetails(of: maria))
        #expect(details.reports.map(\.name) == ["Sam Okafor"] && details.recent.count == 2 && details.moreFiles != nil)
    }
}
