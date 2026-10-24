import AppIntents
import GeoToolbox
import ParleyDomain

/// A Spotlight conversation result opens the conversation, as Open Conversation does.
@available(macOS 27, *)
struct SiriOpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let isDiscoverable = false  // Shortcuts has Open Conversation already
    @Parameter(title: "Conversation") var target: SiriConversation
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        await store.select(ConversationID(target.id))
        return .result()
    }
}

/// A Spotlight person result opens the DM with them, started when there's none.
@available(macOS 27, *)
struct SiriOpenPersonIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Direct Message"
    static let isDiscoverable = false  // Shortcuts has Open Direct Message already
    @Parameter(title: "Person") var target: SiriPerson
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        let known =
            PersonEntity.known(in: store.rooms.conversations, me: store.me.id).first { $0.id.rawValue == target.id }
            ?? Person(id: PersonID(target.id), name: target.name)
        try await store.message([known])
        return .result()
    }
}

/// "Mark this message as unread": unread from it on, as its menu does; read clears its conversation.
@available(macOS 27, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct SiriSetReadStatusIntent {
    var message: SiriMessage
    var isRead: Bool
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        guard let found = store.history.messages.first(where: { $0.id.rawValue == message.id }) else {
            throw ParleyIntentError.failed("Parley can't find that message.")
        }
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
        try await requestConfirmation(
            actionName: .continue, dialog: "Change your message in \(message.conversation.displayName) to “\(text)”?")
        guard await store.editText(of: MessageID(message.id), to: text) else {
            throw ParleyIntentError.failed(
                "Parley couldn't edit that message. Only your own sent messages can be edited.")
        }
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
        try await requestConfirmation(
            actionName: .continue,
            dialog:
                "Delete “\(message.body.map { String($0.characters) } ?? "")” for everyone in \(message.conversation.displayName)?"
        )
        guard await store.unsend(MessageID(message.id)) else {
            throw ParleyIntentError.failed(
                "Parley couldn't delete that message. Only your own sent messages can be deleted.")
        }
        return .result()
    }
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
    static var supportedModes: IntentModes { .foreground }  // what replaces openAppWhenRun from macOS 26
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        guard let destination else {
            store.newChatRequests += 1
            return .result()
        }
        let room = try await store.conversation(for: destination)
        await store.select(room.id)
        if let content { store.share(Shared(text: String(content.characters), files: []), to: room.id) }
        return .result()
    }
}

/// Siri learns whom I message from the sends I make in Parley: each is donated with its recipient, never its text.
@available(macOS 27, *)
enum SiriDonation {
    /// The recipient Siri would name for this conversation: the person in a 1:1 DM, else the conversation itself.
    static func destination(for conversation: Conversation, me: PersonID) -> SiriDestination {
        if conversation.kind == .direct, let person = conversation.members.first(where: { $0.id != me }) {
            return .messagePerson(SiriPerson(person))
        }
        return .messagePerson(SiriPerson(recipient: conversation))
    }
    @MainActor static func donate(_ conversation: Conversation, me: PersonID) {
        let intent = SiriSendMessageIntent()
        intent.destination = destination(for: conversation, me: me)
        Task { _ = try? await IntentDonationManager.shared.donate(intent: intent) }
    }
}
