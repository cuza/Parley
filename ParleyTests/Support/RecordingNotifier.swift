@testable import Parley
@testable import ParleyDomain

/// A notifier that keeps what the store posted and cleared, for tests to read.
@MainActor final class RecordingNotifier: Notifier {
    var posted: [ChatNotification] = []
    var cleared: [ConversationID] = []
    func post(_ notification: ChatNotification) { posted.append(notification) }
    func clear(conversation: ConversationID) { cleared.append(conversation) }
}
