import AppIntents
import CoreSpotlight
import GeoToolbox
import LinkPresentation

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
    let id: PersonID
    var person: IntentPerson
    let name: String
    init(_ person: Person) {
        id = person.id; name = person.name
        self.person = IntentPerson(identifier: .applicationDefined(person.id), name: .displayName(person.name),
                                   handle: person.email.map { IntentPerson.Handle(emailAddress: $0) })
    }
    /// A space or group chat offered to Siri as a recipient: the send template takes people only on this SDK, so "send a
    /// message to the design team" resolves to this, and the send goes to the conversation itself.
    init(recipient conversation: Conversation) {
        id = conversation.id; name = conversation.name
        person = IntentPerson(identifier: .applicationDefined(conversation.id), name: .displayName(conversation.name),
                              handle: IntentPerson.Handle(applicationDefined: conversation.id))
    }
    /// Spaces and group chats, as recipients.
    static func recipients(_ conversations: [Conversation]) -> [SiriPerson] {
        conversations.filter { $0.kind != .direct && $0.hidden == nil }.map(SiriPerson.init(recipient:))
    }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    struct SiriPersonQuery: EntityStringQuery {
        @Dependency private var store: ChatStore
        @MainActor func entities(for identifiers: [PersonID]) async throws -> [SiriPerson] {
            await store.listed()
            return (PersonEntity.known(in: store.conversations, me: store.me.id).map(SiriPerson.init) + SiriPerson.recipients(store.conversations))
                .filter { identifiers.contains($0.id) }
        }
        @MainActor func entities(matching string: String) async throws -> [SiriPerson] {
            await store.listed()
            return PersonEntity.known(matching: string, in: store.conversations, me: store.me.id).map(SiriPerson.init)
                + SiriPerson.recipients(ConversationEntity.matching(string, in: store.conversations))
        }
    }
}

@available(macOS 27, *)
@AppEntity(schema: .messages.conversation)
struct SiriConversation {
    static let defaultQuery = SiriConversationQuery()
    let id: ConversationID
    var recipients: [SiriPerson]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<SiriConversationAttribute>
    var dateLastActive: Date?
    init(_ conversation: Conversation, me: PersonID) {
        id = conversation.id
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
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(displayName)") }
    struct SiriConversationQuery: EntityStringQuery {
        @Dependency private var store: ChatStore
        @MainActor func entities(for identifiers: [ConversationID]) async throws -> [SiriConversation] {
            await store.listed()
            return store.conversations.filter { identifiers.contains($0.id) }.map { SiriConversation($0, store: store) }
        }
        @MainActor func entities(matching string: String) async throws -> [SiriConversation] {
            await store.listed()
            return ConversationEntity.matching(string, in: store.conversations).map { SiriConversation($0, store: store) }
        }
        @MainActor func suggestedEntities() async throws -> [SiriConversation] {
            await store.listed()
            return ConversationEntity.suggested(store.conversations).map { SiriConversation($0, store: store) }
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
    let id: MessageID
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
        id = message.id
        messageType = .unspecified
        author = SiriPerson(message.sender)
        isRead = true
        attributes = message.edited ? [.edited] : []
        self.conversation = conversation
        date = message.createdAt
        body = AttributedString(message.text)
        attachments = []; customAttachments = []; locations = []; links = []
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(body ?? "")", subtitle: "\(conversation.displayName)")
    }
    /// Messages Parley has loaded: those on screen, in a banner, or just sent. "My last message" is suggested from the open conversation.
    struct SiriMessageQuery: EntityStringQuery {
        @Dependency private var store: ChatStore
        @MainActor func entities(for identifiers: [MessageID]) async throws -> [SiriMessage] {
            entities(store.messages.filter { identifiers.contains($0.id) })
        }
        /// Words from a loaded message, newest first; nothing leaves the Mac and nothing is indexed.
        @MainActor func entities(matching string: String) async throws -> [SiriMessage] {
            entities(Array(store.messages.filter { !$0.isSystem && $0.text.localizedStandardContains(string) }
                .sorted { $0.createdAt > $1.createdAt }.prefix(20)))
        }
        @MainActor func suggestedEntities() async throws -> [SiriMessage] {
            guard let open = store.selectedID else { return [] }
            return entities(Array(store.timeline(open).filter { !$0.isSystem && $0.delivery == .sent }.suffix(10).reversed()))
        }
        @MainActor private func entities(_ messages: [Message]) -> [SiriMessage] {
            messages.compactMap { message in
                store.conversations.first { $0.id == message.conversationID }.map { SiriMessage(message, in: SiriConversation($0, store: store)) }
            }
        }
    }
}

/// Who Siri's send or draft goes to: one person or a group of people. Apple's template takes people, not a conversation, so
/// a space can't be named here; Parley's own Send Message action covers spaces.
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

/// A Spotlight conversation result opens the conversation, as Open Conversation does.
@available(macOS 27, *)
struct SiriOpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let isDiscoverable = false   // Shortcuts has Open Conversation already
    @Parameter(title: "Conversation") var target: SiriConversation
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        await store.listed()
        await store.select(target.id)
        return .result()
    }
}

/// A Spotlight person result opens the DM with them, started when there's none.
@available(macOS 27, *)
struct SiriOpenPersonIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Direct Message"
    static let isDiscoverable = false   // Shortcuts has Open Direct Message already
    @Parameter(title: "Person") var target: SiriPerson
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        await store.listed()
        let known = PersonEntity.known(in: store.conversations, me: store.me.id).first { $0.id == target.id } ?? Person(id: target.id, name: target.name)
        try await store.message([known])
        return .result()
    }
}

/// Every Google Chat conversation and message is shared with others, so Siri confirms before acting on one.
@available(macOS 27, *)
extension SiriConversation: OwnershipProvidingEntity { var ownership: EntityOwnership { .shared } }
@available(macOS 27, *)
extension SiriMessage: OwnershipProvidingEntity { var ownership: EntityOwnership { .shared } }

/// "Mark this message as unread": unread from it on, as its menu does; read clears its conversation.
@available(macOS 27, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct SiriSetReadStatusIntent {
    var message: SiriMessage
    var isRead: Bool
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        guard let found = store.messages.first(where: { $0.id == message.id }) else { throw ParleyIntentError.failed("Parley can't find that message.") }
        await store.setRead(isRead, found)
        return .result()
    }
}

/// "Edit my last message to say …": mine only, confirmed first, sent as plain text.
@available(macOS 27, *)
@AppIntent(schema: .messages.editSentMessage)
struct SiriEditSentMessageIntent {
    var message: SiriMessage
    var content: AttributedString
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        let text = String(content.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParleyIntentError.emptyMessage }
        try await requestConfirmation(actionName: .continue, dialog: "Change your message in \(message.conversation.displayName) to “\(text)”?")
        guard await store.editText(of: message.id, to: text) else { throw ParleyIntentError.failed("Parley couldn't edit that message. Only your own sent messages can be edited.") }
        return .result()
    }
}

/// "Unsend that": one of my messages deleted for everyone, after confirming.
@available(macOS 27, *)
@AppIntent(schema: .messages.unsendMessage)
struct SiriUnsendMessageIntent {
    var message: SiriMessage
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        try await requestConfirmation(actionName: .continue, dialog: "Delete “\(message.body.map { String($0.characters) } ?? "")” for everyone in \(message.conversation.displayName)?")
        guard await store.unsend(message.id) else { throw ParleyIntentError.failed("Parley couldn't delete that message. Only your own sent messages can be deleted.") }
        return .result()
    }
}

@available(macOS 27, *)
@UnionValue
enum SiriDestination {
    case people([IntentPerson])   // from Contacts: matched to Google Chat people by email, then by name
    case messagePerson(SiriPerson)
    case messagePeople([SiriPerson])
}

/// Siri's "send a message": confirmed first, as Parley's own Send Message is, then sent as typed text.
@available(macOS 27, *)
@AppIntent(schema: .messages.sendMessage)
struct SiriSendMessageIntent {
    var content: AttributedString?
    var destination: SiriDestination
    var subject: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?
    static let isAssistantOnly = true
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some ReturnsValue<[SiriMessage]> {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        let text = String((content ?? "").characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParleyIntentError.emptyMessage }
        let room = try await store.conversation(for: destination)
        try await requestConfirmation(actionName: .send, dialog: "Send “\(text)” to \(room.name)?")
        guard await store.sendText(text, to: room.id) else { throw ParleyIntentError.notSent(room.name) }
        let sent = store.timeline(room.id).last { $0.sender.id == store.me.id && $0.text == text }
        let conversation = SiriConversation(room, store: store)
        return .result(value: sent.map { [SiriMessage($0, in: conversation)] } ?? [])
    }
}

/// Siri's "start a message": the conversation opens with the words in its composer, unsent.
@available(macOS 27, *)
@AppIntent(schema: .messages.draftMessage)
struct SiriDraftMessageIntent {
    var destination: SiriDestination?
    var subject: AttributedString?
    var content: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?
    static let openAppWhenRun = true
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        guard let destination else { store.newChatRequests += 1; return .result() }
        let room = try await store.conversation(for: destination)
        await store.select(room.id)
        if let content { store.share(Shared(text: String(content.characters), files: []), to: room.id) }
        return .result()
    }
}

@available(macOS 27, *)
extension ChatStore {
    /// The conversation a Siri destination names: the DM or group chat with exactly those people, found or started.
    func conversation(for destination: SiriDestination) async throws -> Conversation {
        await listed()
        // A space or group chat named as a recipient is that conversation.
        let named: [SiriPerson] = switch destination {
        case .messagePerson(let person): [person]
        case .messagePeople(let people): people
        case .people: []
        }
        if named.count == 1, let room = conversations.first(where: { $0.id == named[0].id }) { return room }
        let known = PersonEntity.known(in: conversations, me: me.id)
        let people: [Person]
        switch destination {
        case .messagePerson(let person): people = [known.first { $0.id == person.id } ?? Person(id: person.id, name: person.name)]
        case .messagePeople(let entities): people = entities.map { entity in known.first { $0.id == entity.id } ?? Person(id: entity.id, name: entity.name) }
        case .people(let contacts):
            var found: [Person] = []
            for contact in contacts { found.append(try await chatPerson(for: contact, known: known)) }
            people = found
        }
        try await message(people)
        if let id = selectedID, let room = conversations.first(where: { $0.id == id }) { return room }
        throw ParleyIntentError.failed("Parley can't find that conversation.")
    }
    /// A contact as a Google Chat person: by email among people I chat with, then by name, then Google Chat's directory.
    func chatPerson(for contact: IntentPerson, known: [Person]) async throws -> Person {
        var email: String?
        if case .emailAddress(let address)? = contact.handle?.value { email = address }
        let name: String? = switch contact.name {
        case .displayName(let name): name
        case .components(let parts): PersonNameComponentsFormatter().string(from: parts)
        default: nil
        }
        if let email, let person = known.first(where: { $0.email?.caseInsensitiveCompare(email) == .orderedSame }) { return person }
        if let name, let person = known.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return person }
        for query in [email, name].compactMap({ $0 }) {
            if let person = try? await searchPeople(query).first(where: { $0.id != me.id }) { return person }
        }
        throw ParleyIntentError.failed("Parley can't find \(name ?? email ?? "that person") in Google Chat.")
    }
}

/// Siri learns whom I message from the sends I make in Parley: each is donated with its recipient, never its text.
@available(macOS 27, *)
enum SiriDonation {
    /// The recipient Siri would name for this conversation: the person in a 1:1 DM, else the conversation itself.
    static func destination(for conversation: Conversation, me: PersonID) -> SiriDestination {
        if conversation.kind == .direct, let person = conversation.members.first(where: { $0.id != me }) { return .messagePerson(SiriPerson(person)) }
        return .messagePerson(SiriPerson(recipient: conversation))
    }
    @MainActor static func donate(_ conversation: Conversation, me: PersonID) {
        let intent = SiriSendMessageIntent()
        intent.destination = destination(for: conversation, me: me)
        Task { _ = try? await IntentDonationManager.shared.donate(intent: intent) }
    }
}
