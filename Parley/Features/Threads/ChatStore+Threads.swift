import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    /// The Threads button: shows the list when it isn't on screen (hidden, under an open thread, or replaced by the info
    /// panel), and closes it when it is.
    func toggleThreads(window: ConversationID? = nil) async {
        let pane = navigation.pane(window)
        await showThreads(!(pane.threads && pane.thread == nil && !pane.info), window: window)
    }
    func showThreads(_ shown: Bool, window: ConversationID? = nil) async {
        navigation.setPane(window) { $0.threads = shown }
        guard shown, let id = window ?? navigation.selectedID else { return }
        navigation.setPane(window) { $0.content = nil }
        await loadThreads(id)
    }
    func loadThreads(_ id: ConversationID) async {
        do { history.threadSummaries[id] = try await backend.threads(in: id) } catch { report(error) }
    }
    /// Opens a message's thread in a window's side pane: nil for the main window, else a conversation window's conversation.
    func openThread(_ message: Message, window: ConversationID? = nil) async {
        await openThread(message.threadID ?? ThreadID(head: message.id), in: message.conversationID, window: window)
    }
    func openThread(
        _ thread: ThreadID, in conversation: ConversationID, recording: Bool = true, window: ConversationID? = nil
    ) async {
        if window == nil, recording, self.conversation(conversation)?.app == .gemini {
            visit(.session(conversation, thread))
        }
        navigation.setPane(window) { $0.openThread(thread) }
        history.loaded.remove(key(conversation, thread))
        await load(conversation, thread: thread)
        guard navigation.pane(window).thread == thread, window != nil || navigation.selectedID == conversation else {
            return
        }
        await readThread(thread)
    }
    /// An open thread is read up to its newest reply, on the server too, so it reads as read on the web and phone.
    /// `upTo`: the newest reply when none of the thread is loaded (Home's thread, read from Mark All as Read).
    func readThread(_ thread: ThreadID, upTo latest: Date? = nil) async {
        guard
            let newest = history.messages.lazy.filter({ $0.threadID == thread || $0.id == thread.head }).map(
                \.createdAt
            ).max() ?? latest
        else { return }
        if let index = rooms.homeThreads.firstIndex(where: { $0.id == thread }), rooms.homeThreads[index].unread {
            rooms.homeThreads[index].unread = false
        }
        do {
            try await backend.markRead(thread: thread, upTo: newest)
        } catch {
            log.error("mark thread read failed: \(Redaction.redact(String(describing: error)), privacy: .public)")
        }
    }
    func isFollowing(_ thread: ThreadID) -> Bool { followed.contains(thread) }
    /// Shown at once; Google's label event confirms it, and a refusal puts it back and says why.
    func setFollowing(_ following: Bool, for thread: ThreadID) async {
        let was = followed.contains(thread)
        let undoable = Undoable(following ? "Follow Thread" : "Unfollow Thread") {
            await self.setFollowing(!following, for: thread)
        }
        await optimistically(.toast(following ? "follow the thread" : "unfollow the thread"), undoable: undoable) {
            if following { followed.insert(thread) } else { followed.remove(thread) }
        } undo: {
            if was { followed.insert(thread) } else { followed.remove(thread) }
        } send: {
            try await backend.setFollowing(following, for: thread)
            if !following { rooms.homeThreads.removeAll { $0.id == thread } }  // Home lists followed threads only
        }
    }
    /// The open thread, closed in the pane so it can go to its own window.
    func detachThread(in conversation: ConversationID) -> ThreadRef? {
        guard let thread = navigation.threadID else { return nil }
        navigation.setPane(nil) { $0.closeThread() }
        return ThreadRef(conversation: conversation, thread: thread)
    }
}
