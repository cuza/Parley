import AppIntents
import ParleyDomain

/// Shortcuts' and Spotlight's Open Conversation: Parley comes forward on it, as a Google Chat link opens it.
struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a Google Chat conversation in Parley.")
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }
    @Parameter(title: "Conversation") var target: ConversationEntity
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        await store.select(ConversationID(target.id))
        return .result()
    }
}

/// The Conversation menu's Mark as Read, Mute and Pin, as Shortcuts actions that take a conversation.
struct MarkConversationReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Conversation as Read"
    static let description = IntentDescription("Marks a Google Chat conversation as read in Parley.")
    static var parameterSummary: some ParameterSummary { Summary("Mark \(\.$conversation) as read") }
    @Parameter(title: "Conversation") var conversation: ConversationEntity
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        await store.markRead(ConversationID(conversation.id))
        return .result()
    }
}

struct MuteConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Conversation"
    static let description = IntentDescription("Mutes or unmutes a Google Chat conversation in Parley.")
    static var parameterSummary: some ParameterSummary { Summary("\(\.$muted) \(\.$conversation)") }
    @Parameter(title: "Conversation") var conversation: ConversationEntity
    @Parameter(title: "Mute", default: true, displayName: Bool.IntentDisplayName(true: "Mute", false: "Unmute"))
    var muted: Bool
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        await store.setMuted(muted, ConversationID(conversation.id))
        return .result()
    }
}

struct PinConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Conversation"
    static let description = IntentDescription("Pins or unpins a Google Chat conversation in Parley's sidebar.")
    static var parameterSummary: some ParameterSummary { Summary("\(\.$pinned) \(\.$conversation)") }
    @Parameter(title: "Conversation") var conversation: ConversationEntity
    @Parameter(title: "Pin", default: true, displayName: Bool.IntentDisplayName(true: "Pin", false: "Unpin"))
    var pinned: Bool
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        await store.setSidebarPinned(pinned, ConversationID(conversation.id))
        return .result()
    }
}

/// Shortcuts' and Siri's Send Message. It always asks before sending, showing the text and the conversation, since a
/// misheard or mistyped name would otherwise send to the wrong person; Parley stays where it is.
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription(
        "Sends a message to a Google Chat space, group chat or direct message with Parley, once you confirm it. Use it to message a space by its name."
    )
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to \(\.$conversation)") }
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "Space or chat", description: "The Google Chat space, group chat or direct message to send to.")
    var conversation: ConversationEntity
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParleyIntentError.emptyMessage }
        try await requestConfirmation(actionName: .send, dialog: "Send “\(text)” to \(conversation.name)?")
        await store.listed()
        guard await store.sendText(text, to: ConversationID(conversation.id)) else {
            throw ParleyIntentError.notSent(conversation.name)
        }
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

/// Message a Person: the DM with them opens in Parley, started on the server when there's none yet.
struct MessagePersonIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Direct Message"
    static let description = IntentDescription(
        "Opens your direct message with someone in Parley, starting one if you have none.")
    static var parameterSummary: some ParameterSummary { Summary("Open the direct message with \(\.$person)") }
    static let openAppWhenRun = true
    @available(macOS 26, *) static var supportedModes: IntentModes { .foreground }  // what replaces openAppWhenRun from macOS 26
    @Parameter(title: "Person") var person: PersonEntity
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        try await store.message([person.person])
        return .result()
    }
}

/// Opens Parley's message search with these words, filters and results as ⌘F shows them.
struct SearchMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Messages"
    static let description = IntentDescription("Opens Parley's message search with these words.")
    static var parameterSummary: some ParameterSummary { Summary("Search Parley for \(\.$query)") }
    static let openAppWhenRun = true
    @available(macOS 26, *) static var supportedModes: IntentModes { .foreground }  // what replaces openAppWhenRun from macOS 26
    @Parameter(title: "Words") var query: String
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        store.searchRequest = SearchRequest(query: query)
        return .result()
    }
}

struct MarkAllReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark All as Read"
    static let description = IntentDescription(
        "Marks every Google Chat conversation as read, as the Dock menu's Mark All as Read does.")
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.signedInAndListed()
        await store.markAllRead()
        return .result()
    }
}
