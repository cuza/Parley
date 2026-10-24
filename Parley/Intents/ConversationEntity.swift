import AppIntents
import CoreSpotlight
import CoreTransferable
import ParleyDomain

/// A conversation as Shortcuts, Spotlight and Siri see it: its name, with its kind as the subtitle. Queries read the
/// conversations Parley already has, so they work offline and cost no requests.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Conversation", synonyms: ["Space", "Chat", "Group chat", "Direct message"])
    static let defaultQuery = ConversationQuery()
    let id: String  // the conversation's id, as App Intents and Spotlight keep it
    @Property(title: "Name") var name: String
    @Property(title: "Kind") var kind: Kind
    let keywords: [String]  // its members' names, so a person's name finds the spaces they're in
    init(_ conversation: Conversation) {
        id = conversation.id.rawValue
        keywords = conversation.members.map(\.name)
        name = conversation.name
        kind = Kind(conversation)
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind.name)", image: .init(systemName: kind.symbol))
    }
    /// What kind of conversation it is: a choice Shortcuts can filter on, and the row's subtitle and symbol.
    enum Kind: String, AppEnum {
        case space, group, direct, app
        init(_ conversation: Conversation) {
            switch conversation.kind {
            case .space: self = .space
            case .group: self = .group
            case .direct: self = conversation.app == nil ? .direct : .app
            }
        }
        var name: String {
            switch self {
            case .space: "Space"
            case .group: "Group chat"
            case .direct: "Direct message"
            case .app: "App"
            }
        }
        /// As the sidebar draws them: a space's "#", a person, people, an app.
        var symbol: String {
            switch self {
            case .space: "number"
            case .group: "person.2"
            case .direct: "person.crop.circle"
            case .app: "app"
            }
        }
        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kind"
        static let caseDisplayRepresentations: [Kind: DisplayRepresentation] = [
            .space: DisplayRepresentation(title: "Space", image: .init(systemName: "number")),
            .group: DisplayRepresentation(title: "Group chat", image: .init(systemName: "person.2")),
            .direct: DisplayRepresentation(title: "Direct message", image: .init(systemName: "person.crop.circle")),
            .app: DisplayRepresentation(title: "App", image: .init(systemName: "app")),
        ]
    }
    /// What Shortcuts offers before anything is typed: pinned conversations, then the most recent, ten at most.
    static func suggested(_ conversations: [Conversation]) -> [Conversation] {
        Array(
            conversations.filter { $0.hidden == nil }
                .sorted {
                    ($0.pinned ? 1 : 0, $0.activity ?? .distantPast) > ($1.pinned ? 1 : 0, $1.activity ?? .distantPast)
                }
                .prefix(10))
    }
    /// A typed name, matched as Finder matches: case and accents aside.
    static func matching(_ text: String, in conversations: [Conversation]) -> [Conversation] {
        conversations.filter { $0.name.localizedStandardContains(text) }
    }
}

/// In Spotlight by name, kind and members' names; never message text.
extension ConversationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.displayName = name
        attributes.contentDescription = kind.name
        attributes.keywords = keywords
        return attributes
    }
}

/// Shared, or handed to Siri as what's on screen, a conversation is its Google Chat link.
extension ConversationEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { ChatLink.url(ConversationID($0.id)) }
    }
}

struct ConversationQuery: EntityStringQuery {
    @Dependency private var store: ChatStore
    // Each waits for the first conversation list, as an action that launched Parley arrives before it.
    @MainActor func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        await store.listed()
        return store.rooms.conversations.filter { identifiers.contains($0.id.rawValue) }.map(ConversationEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [ConversationEntity] {
        await store.listed()
        return ConversationEntity.matching(string, in: store.rooms.conversations).map(ConversationEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [ConversationEntity] {
        await store.listed()
        return ConversationEntity.suggested(store.rooms.conversations).map(ConversationEntity.init)
    }
}

/// Spotlight asks for the index again when it lost it or changed format: rebuilt from the conversations Parley has.
@available(macOS 27, *)
extension ConversationQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        await reindex()
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws { await reindex() }
    @MainActor private func reindex() async {
        await store.listed()
        await ConversationSpotlight.rebuild(store.rooms.conversations, me: store.me.id)
    }
}
