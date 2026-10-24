import AppIntents
import ParleyDomain

/// A person as Shortcuts and Siri see them: name, and email when Google Chat gives one.
struct PersonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static let defaultQuery = PersonQuery()
    let id: String  // the person's id, as App Intents keeps it
    let name: String
    let email: String?
    init(_ person: Person) {
        id = person.id.rawValue
        name = person.name
        email = person.email
    }
    var person: Person { Person(id: PersonID(id), name: name, email: email) }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: email.map { "\($0)" }, image: .init(systemName: "person.crop.circle"))
    }
    /// Everyone in my conversations, each once, in the order they first appear; never me.
    static func known(in conversations: [Conversation], me: PersonID) -> [Person] {
        var seen: Set<PersonID> = [me]
        return conversations.flatMap(\.members).filter { seen.insert($0.id).inserted }
    }
    static func known(matching text: String, in conversations: [Conversation], me: PersonID) -> [Person] {
        known(in: conversations, me: me).filter {
            $0.name.localizedStandardContains(text) || $0.email?.localizedStandardContains(text) == true
        }
    }
}

/// People from my conversations first; anyone else from Google Chat's directory once nobody known matches.
struct PersonQuery: EntityStringQuery {
    @Dependency private var store: ChatStore
    @MainActor func entities(for identifiers: [String]) async throws -> [PersonEntity] {
        await store.listed()
        return PersonEntity.known(in: store.rooms.conversations, me: store.me.id).filter {
            identifiers.contains($0.id.rawValue)
        }.map(PersonEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [PersonEntity] {
        await store.listed()
        let known = PersonEntity.known(matching: string, in: store.rooms.conversations, me: store.me.id)
        let people = known.isEmpty ? (try? await store.searchPeople(matching: string)) ?? [] : known
        return people.filter { $0.id != store.me.id }.map(PersonEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [PersonEntity] {
        await store.listed()
        let direct = ConversationEntity.suggested(store.rooms.conversations).filter {
            $0.kind == .direct && $0.app == nil
        }
        return PersonEntity.known(in: direct, me: store.me.id).map(PersonEntity.init)
    }
}
