import AppIntents

/// A person as Shortcuts and Siri see them: name, and email when Google Chat gives one.
struct PersonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static let defaultQuery = PersonQuery()
    let id: PersonID
    let name: String
    let email: String?
    init(_ person: Person) { id = person.id; name = person.name; email = person.email }
    var person: Person { Person(id: id, name: name, email: email) }
    var displayRepresentation: DisplayRepresentation {
        email.map { DisplayRepresentation(title: "\(name)", subtitle: "\($0)") } ?? DisplayRepresentation(title: "\(name)")
    }
    /// Everyone in my conversations, each once, in the order they first appear; never me.
    static func known(in conversations: [Conversation], me: PersonID) -> [Person] {
        var seen: Set<PersonID> = [me]
        return conversations.flatMap(\.members).filter { seen.insert($0.id).inserted }
    }
    static func known(matching text: String, in conversations: [Conversation], me: PersonID) -> [Person] {
        known(in: conversations, me: me).filter { $0.name.localizedStandardContains(text) || $0.email?.localizedStandardContains(text) == true }
    }
}

/// People from my conversations first; anyone else from Google Chat's directory once nobody known matches.
struct PersonQuery: EntityStringQuery {
    @Dependency private var store: ChatStore
    @MainActor func entities(for identifiers: [PersonID]) async throws -> [PersonEntity] {
        await store.listed()
        return PersonEntity.known(in: store.conversations, me: store.me.id).filter { identifiers.contains($0.id) }.map(PersonEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [PersonEntity] {
        await store.listed()
        let known = PersonEntity.known(matching: string, in: store.conversations, me: store.me.id)
        let people = known.isEmpty ? (try? await store.searchPeople(string)) ?? [] : known
        return people.filter { $0.id != store.me.id }.map(PersonEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [PersonEntity] {
        await store.listed()
        let direct = ConversationEntity.suggested(store.conversations).filter { $0.kind == .direct && $0.app == nil }
        return PersonEntity.known(in: direct, me: store.me.id).map(PersonEntity.init)
    }
}

/// Message a Person: the DM with them opens in Parley, started on the server when there's none yet.
struct MessagePersonIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Direct Message"
    static let description = IntentDescription("Opens your direct message with someone in Parley, starting one if you have none.")
    static var parameterSummary: some ParameterSummary { Summary("Open the direct message with \(\.$person)") }
    static let openAppWhenRun = true
    @Parameter(title: "Person") var person: PersonEntity
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        await store.listed()
        try await store.message([person.person])
        return .result()
    }
}
