import AppIntents

/// The Conversation menu's Mark as Read, Mute and Pin, as Shortcuts actions that take a conversation.
struct MarkConversationReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Conversation as Read"
    static let description = IntentDescription("Marks a Google Chat conversation as read in Parley.")
    static var parameterSummary: some ParameterSummary { Summary("Mark \(\.$conversation) as read") }
    @Parameter(title: "Conversation") var conversation: ConversationEntity
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        await store.listed()
        await store.markRead(conversation.id)
        return .result()
    }
}

struct MuteConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Conversation"
    static let description = IntentDescription("Mutes or unmutes a Google Chat conversation in Parley.")
    static var parameterSummary: some ParameterSummary { Summary("\(\.$muted) \(\.$conversation)") }
    @Parameter(title: "Conversation") var conversation: ConversationEntity
    @Parameter(title: "Mute", default: true, displayName: Bool.IntentDisplayName(true: "Mute", false: "Unmute")) var muted: Bool
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        await store.listed()
        await store.setMuted(muted, conversation.id)
        return .result()
    }
}

struct PinConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Conversation"
    static let description = IntentDescription("Pins or unpins a Google Chat conversation in Parley's sidebar.")
    static var parameterSummary: some ParameterSummary { Summary("\(\.$pinned) \(\.$conversation)") }
    @Parameter(title: "Conversation") var conversation: ConversationEntity
    @Parameter(title: "Pin", default: true, displayName: Bool.IntentDisplayName(true: "Pin", false: "Unpin")) var pinned: Bool
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        await store.listed()
        await store.setPinned(pinned, conversation.id)
        return .result()
    }
}
