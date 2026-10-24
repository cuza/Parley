import AppIntents

/// Ready-made phrases. Whether macOS's Siri uses them is unclear; the actions are in Shortcuts either way. They name only
/// the app: a phrase with a conversation in it needs updateAppShortcutParameters() after every conversation list, worth
/// adding once Siri on the Mac is seen to use phrases.
struct ParleyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenConversationIntent(), phrases: ["Open a conversation in \(.applicationName)"],
            shortTitle: "Open Conversation", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: SendMessageIntent(), phrases: ["Send a message with \(.applicationName)"],
            shortTitle: "Send Message", systemImageName: "paperplane")
        AppShortcut(
            intent: SearchMessagesIntent(), phrases: ["Search \(.applicationName)"],
            shortTitle: "Search Messages", systemImageName: "magnifyingglass")
        AppShortcut(
            intent: MarkAllReadIntent(), phrases: ["Mark everything read in \(.applicationName)"],
            shortTitle: "Mark All as Read", systemImageName: "checkmark.message")
        AppShortcut(
            intent: SetDoNotDisturbIntent(), phrases: ["Turn on Do Not Disturb in \(.applicationName)"],
            shortTitle: "Do Not Disturb", systemImageName: "moon")
    }
}

enum ParleyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut, emptyMessage
    case notSent(String)
    case failed(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Parley first."
        case .emptyMessage: "There's no message to send."
        case .notSent(let name):
            "Parley couldn't send the message to \(name). It's in the conversation, marked as not sent."
        case .failed(let problem): "\(problem)"
        }
    }
}

extension ChatStore {
    /// Throws unless signed in, then waits for the first conversation list, which an action that launched Parley arrives before.
    func signedInAndListed() async throws {
        if needsSignIn { throw ParleyIntentError.signedOut }
        await listed()
    }
    /// A status change from an action: signed in first, and the store's error thrown rather than shown in a window.
    func changeStatus(_ change: (ChatStore) async -> Void) async throws {
        if needsSignIn { throw ParleyIntentError.signedOut }
        error = nil
        await change(self)
        if let problem = error {
            error = nil
            throw ParleyIntentError.failed(problem)
        }
    }
}
