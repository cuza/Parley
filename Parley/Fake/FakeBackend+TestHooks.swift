import Foundation
import ParleyDomain

// Test hooks: what a test makes the demo do next, or pushes as Google Chat would.
extension FakeBackend {
    func simulateSignedOut() { signedOut = true }
    func simulateAccount(_ person: Person) { account = person }
    /// Google stops accepting the session mid-use, without the backend reporting it as an event first.
    func simulateSessionExpiredOnNextSend(_ failure: AuthFailure = .signInRequired) { expireOnNextSend = failure }
    /// A start that was superseded or whose view went away, as the window closing mid-connect does.
    func simulateCancelledConnect() { cancelNextConnect = true }
    /// Google refusing a conversation's history (HTTP 403).
    func simulateRefusedHistory(_ conversation: ConversationID) { refusedHistory.insert(conversation) }
    /// Someone typing, or an app at work, as Google Chat pushes them; the demo's -uiTestingTyping repeats these.
    func simulateTyping(_ person: PersonID, in conversation: ConversationID, thread: ThreadID? = nil) {
        continuation.yield(.typingChanged(conversation, thread, person, isTyping: true))
    }
    func simulateActivity(_ person: PersonID, in conversation: ConversationID, label: String) {
        continuation.yield(.activityChanged(conversation, nil, person, label: label))
    }
    /// Someone else's message, pushed as Google Chat pushes one.
    func simulateIncoming(_ message: Message) {
        history.append(message)
        continuation.yield(.messageUpserted(message))
    }
    func simulateReadFailure() { failNextRead = true }
    func simulateChangeFailure() { failNextChange = true }
    func disallowTyping(in conversation: ConversationID) { typingDisallowed.insert(conversation) }
    func simulateCustomEmoji(_ allowed: Bool, in conversation: ConversationID) {
        customEmojiAllowed[conversation] = allowed
    }
    func refuseTyping(in scope: String) { typingRefused.insert(scope) }
    func simulateDirectoryFailure() { failDirectory = true }
    func invite(_ listing: SpaceListing) { listings.insert(listing, at: 0) }
    /// A pin made elsewhere: Google keeps it, and nothing is pushed.
    func simulatePinned(_ id: MessageID) {
        if let index = history.firstIndex(where: { $0.id == id }) { history[index].pinned = true }
    }
    func setHomeThreads(_ threads: [HomeThread]) { serverHome = threads }
    func simulateDraftFailure(_ fail: Bool = true) { failDraftWrites = fail }
    /// Draft saves that take this long, so a send can happen while one is on its way.
    func simulateSlowDraftWrites(_ latency: Duration) { draftLatency = latency }
    func simulateDrafts(_ drafts: [ServerDraft]) { serverDrafts = drafts }
    func simulateScheduled(_ messages: [ServerDraft]) { scheduledMessages = messages }
    /// Pushes an event as the server would, for tests and previews.
    func push(_ event: ChatEvent) { continuation.yield(event) }
    /// The next card action is refused, as an app (or the server for it) refuses one, saying why.
    func refuseNextCardClick(_ why: String) { cardRefusal = why }
    /// The next dialog request gets this answer, as an app answers one (another step, a refusal).
    func answerNextDialog(_ answer: DialogAnswer) { dialogAnswer = answer }
}
