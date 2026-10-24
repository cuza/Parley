import AppIntents
import CoreSpotlight
import GeoToolbox
import LinkPresentation
import ParleyDomain

// Siri with Apple Intelligence (macOS 27): Parley's conversations, people and messages in the shapes of Apple's messaging
// templates, so "send a message to Maria in Parley" works in plain words. These sit beside the Shortcuts actions, which
// keep working on macOS 15 and 26.

@available(macOS 27, *)
@AppEnum(schema: .messages.conversationAttribute)
enum SiriConversationAttribute: String {
    case muted
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.muted: "Muted"]
}

@available(macOS 27, *)
@AppEnum(schema: .messages.messageAttribute)
enum SiriMessageAttribute: String {
    case edited
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.edited: "Edited"]
}

@available(macOS 27, *)
@AppEnum(schema: .messages.messageType)
enum SiriMessageType: String {
    case unspecified
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.unspecified: "Unspecified"]
}

@available(macOS 27, *)
@AppEnum(schema: .messages.messageEffect)
enum SiriMessageEffect: String {
    case none
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.none: "None"]
}

/// Google Chat has no attachments outside file types, so there are never any.
@available(macOS 27, *)
@AppEntity(schema: .messages.customAttachment)
struct SiriCustomAttachment {
    static let defaultQuery = SiriCustomAttachmentQuery()
    var id: String
    var sourceName: AttributedString?
    var description: AttributedString?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(description ?? "")") }
    struct SiriCustomAttachmentQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [SiriCustomAttachment] { [] }
    }
}

@available(macOS 27, *)
@AppEntity(schema: .messages.messagePerson)
struct SiriPerson {
    static let defaultQuery = SiriPersonQuery()
    let id: String  // a person's id, or a space's or group chat's as a recipient
    var person: IntentPerson
    let name: String
    let symbol: String  // a person's, or a space's or group chat's as a recipient
    init(_ person: Person) {
        id = person.id.rawValue
        name = person.name
        symbol = "person.crop.circle"
        self.person = IntentPerson(
            identifier: .applicationDefined(person.id.rawValue), name: .displayName(person.name),
            handle: person.email.map { IntentPerson.Handle(emailAddress: $0) })
    }
    /// A space or group chat offered to Siri as a recipient: the send template takes people only on this SDK, so "send a
    /// message to the design team" resolves to this, and the send goes to the conversation itself.
    init(recipient conversation: Conversation) {
        id = conversation.id.rawValue
        name = conversation.name
        symbol = ConversationEntity.Kind(conversation).symbol
        person = IntentPerson(
            identifier: .applicationDefined(conversation.id.rawValue), name: .displayName(conversation.name),
            handle: IntentPerson.Handle(applicationDefined: conversation.id.rawValue))
    }
    /// Spaces and group chats, as recipients.
    static func recipients(_ conversations: [Conversation]) -> [SiriPerson] {
        conversations.filter { $0.kind != .direct && $0.hidden == nil }.map(SiriPerson.init(recipient:))
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
    struct SiriPersonQuery: EntityStringQuery {
        @Dependency private var store: ChatStore
        @MainActor func entities(for identifiers: [String]) async throws -> [SiriPerson] {
            await store.listed()
            return
                (PersonEntity.known(in: store.rooms.conversations, me: store.me.id).map(SiriPerson.init)
                + SiriPerson.recipients(store.rooms.conversations))
                .filter { identifiers.contains($0.id) }
        }
        @MainActor func entities(matching string: String) async throws -> [SiriPerson] {
            await store.listed()
            return PersonEntity.known(matching: string, in: store.rooms.conversations, me: store.me.id).map(
                SiriPerson.init)
                + SiriPerson.recipients(ConversationEntity.matching(string, in: store.rooms.conversations))
        }
    }
}

@available(macOS 27, *)
@AppEntity(schema: .messages.conversation)
struct SiriConversation {
    static let defaultQuery = SiriConversationQuery()
    let id: String  // the conversation's id, as App Intents and Spotlight keep it
    var recipients: [SiriPerson]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<SiriConversationAttribute>
    var dateLastActive: Date?
    let symbol: String
    init(_ conversation: Conversation, me: PersonID) {
        id = conversation.id.rawValue
        symbol = ConversationEntity.Kind(conversation).symbol
        recipients = conversation.members.filter { $0.id != me }.map(SiriPerson.init)
        displayName = conversation.name
        previewText = ""
        conversationName = conversation.kind == .direct ? nil : conversation.name
        isRead = conversation.unread == 0
        attributes = conversation.muted ? [.muted] : []
        dateLastActive = conversation.activity
    }
    /// With the last loaded message as its preview, for Siri to read out.
    @MainActor init(_ conversation: Conversation, store: ChatStore) {
        self.init(conversation, me: store.me.id)
        previewText = AttributedString(store.timeline(conversation.id).last?.text ?? "")
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", image: .init(systemName: symbol))
    }
    struct SiriConversationQuery: EntityStringQuery {
        @Dependency private var store: ChatStore
        @MainActor func entities(for identifiers: [String]) async throws -> [SiriConversation] {
            await store.listed()
            return store.rooms.conversations.filter { identifiers.contains($0.id.rawValue) }.map {
                SiriConversation($0, store: store)
            }
        }
        @MainActor func entities(matching string: String) async throws -> [SiriConversation] {
            await store.listed()
            return ConversationEntity.matching(string, in: store.rooms.conversations).map {
                SiriConversation($0, store: store)
            }
        }
        @MainActor func suggestedEntities() async throws -> [SiriConversation] {
            await store.listed()
            return ConversationEntity.suggested(store.rooms.conversations).map { SiriConversation($0, store: store) }
        }
    }
}

@available(macOS 27, *)
@UnionValue
enum SiriReaction {
    case attributedString(AttributedString)
}

@available(macOS 27, *)
@AppEntity(schema: .messages.message)
struct SiriMessage {
    static let defaultQuery = SiriMessageQuery()
    let id: String  // the message's id, as App Intents keeps it
    var messageType: SiriMessageType
    var author: SiriPerson
    var isRead: Bool
    var attributes: Set<SiriMessageAttribute>
    var conversation: SiriConversation
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [SiriCustomAttachment]
    var locations: [PlaceDescriptor]
    var links: [LinkMetadata]
    var messageEffect: SiriMessageEffect?
    var reaction: SiriReaction?
    var referencedMessage: SiriMessage?
    var notificationIdentifier: String?
    @MainActor init(_ message: Message, in conversation: SiriConversation) {
        id = message.id.rawValue
        messageType = .unspecified
        author = SiriPerson(message.sender)
        isRead = true
        attributes = message.edited ? [.edited] : []
        self.conversation = conversation
        date = message.createdAt
        body = AttributedString(message.text)
        attachments = []
        customAttachments = []
        locations = []
        links = []
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(body ?? "")", subtitle: "\(conversation.displayName)")
    }
    /// Messages Parley has loaded: those on screen, in a banner, or just sent. "My last message" is suggested from the open conversation.
    struct SiriMessageQuery: EntityStringQuery {
        @Dependency private var store: ChatStore
        @MainActor func entities(for identifiers: [String]) async throws -> [SiriMessage] {
            entities(store.history.messages.filter { identifiers.contains($0.id.rawValue) })
        }
        /// Words from a loaded message, newest first; nothing leaves the Mac and nothing is indexed.
        @MainActor func entities(matching string: String) async throws -> [SiriMessage] {
            entities(
                Array(
                    store.history.messages.filter { !$0.isSystem && $0.text.localizedStandardContains(string) }
                        .sorted { $0.createdAt > $1.createdAt }.prefix(20)))
        }
        @MainActor func suggestedEntities() async throws -> [SiriMessage] {
            guard let open = store.navigation.selectedID else { return [] }
            return entities(
                Array(store.timeline(open).filter { !$0.isSystem && $0.delivery == .sent }.suffix(10).reversed()))
        }
        @MainActor private func entities(_ messages: [Message]) -> [SiriMessage] {
            messages.compactMap { message in
                store.rooms.conversations.first { $0.id == message.conversationID }.map {
                    SiriMessage(message, in: SiriConversation($0, store: store))
                }
            }
        }
    }
}

/// In Spotlight by name and members' names, so Siri resolves "the design team" or "Maria" to Parley's own.
@available(macOS 27, *)
extension SiriConversation: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.displayName = displayName
        attributes.contentDescription = conversationName == nil ? "Direct message" : "Conversation"
        attributes.keywords = recipients.map(\.name)
        return attributes
    }
}
@available(macOS 27, *)
extension SiriPerson: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.displayName = name
        attributes.contentDescription = "Google Chat"
        if case .emailAddress(let email)? = person.handle?.value { attributes.emailAddresses = [email] }
        return attributes
    }
}

/// Every Google Chat conversation and message is shared with others, so Siri confirms before acting on one.
@available(macOS 27, *)
extension SiriConversation: OwnershipProvidingEntity { var ownership: EntityOwnership { .shared } }
@available(macOS 27, *)
extension SiriMessage: OwnershipProvidingEntity { var ownership: EntityOwnership { .shared } }
