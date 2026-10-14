import AppIntents

/// Shortcuts' and Siri's Send Message. It always asks before sending, showing the text and the conversation, since a
/// misheard or mistyped name would otherwise send to the wrong person; Parley stays where it is.
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription("Sends a message to a Google Chat space, group chat or direct message with Parley, once you confirm it. Use it to message a space by its name.")
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to \(\.$conversation)") }
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "Space or chat", description: "The Google Chat space, group chat or direct message to send to.") var conversation: ConversationEntity
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        if store.needsSignIn { throw ParleyIntentError.signedOut }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParleyIntentError.emptyMessage }
        try await requestConfirmation(actionName: .send, dialog: "Send “\(text)” to \(conversation.name)?")
        await store.listed()
        guard await store.sendText(text, to: conversation.id) else { throw ParleyIntentError.notSent(conversation.name) }
        return .result(dialog: "Sent to \(conversation.name).")
    }
}
