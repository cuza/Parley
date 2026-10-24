import Foundation
import ParleyDomain

extension ChatStore {
    /// Home, as Google Chat's: the conversations with activity, each with its newest timeline message held, and the threads
    /// it lists, each with its newest reply; most recent first. A conversation is ordered by the later of the server's
    /// activity time and that message, so a message pushed since moves it up. `unreadOnly` and `threadsOnly` are web's
    /// "Unread" switch and "Thread" filter.
    func homeRows(unreadOnly: Bool = false, threadsOnly: Bool = false) -> [HomeRow] {
        var newest: [ConversationID: Message] = [:]
        for message in history.messages
        where !message.isSystem && message.threadID == nil
            && newest[message.conversationID].map({ message.createdAt > $0.createdAt }) ?? true
        {
            newest[message.conversationID] = message
        }
        let byID = Dictionary(rooms.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = rooms.homeThreads.compactMap { thread in
            byID[thread.conversationID].map {
                HomeRow(room: $0, last: thread.latest, thread: thread, time: thread.time)
            }
        }
        let heads = Set(rooms.homeThreads.map(\.id))
        let roomRows =
            threadsOnly
            ? []
            : rooms.conversations.compactMap { room -> HomeRow? in
                // As Google Chat: a conversation whose newest message starts a thread shown here appears only as that thread.
                if let last = newest[room.id], heads.contains(ThreadID(head: last.id)) { return nil }
                let time = max(room.activity ?? .distantPast, newest[room.id]?.createdAt ?? .distantPast)
                return time == .distantPast ? nil : HomeRow(room: room, last: newest[room.id], time: time)
            }
        return (roomRows + threads).filter { !unreadOnly || $0.unread }.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time > $1.element.time }
            .map(\.element)
    }
    /// A Home thread row: Home stays on screen and the thread opens in the thread pane beside it, at its newest reply.
    /// The conversation itself is not opened or marked read; the thread is, on the server too (`readThread`).
    func openHomeThread(_ thread: HomeThread) async {
        endMainWindowEdits()
        navigation.shortcut = .home
        navigation.selectedID = thread.conversationID
        navigation.setPane(nil) {
            $0.closePerson()
            $0.closeInfo()
        }
        if let index = rooms.homeThreads.firstIndex(where: { $0.id == thread.id }) {
            rooms.homeThreads[index].unread = false
        }
        await openThread(thread.id, in: thread.conversationID)
        history.highlightedID = thread.latest.id
        await watchOpen()
    }
    /// A Home row's newest page, when the server reports activity after the newest message held (or none is held).
    /// Waits for the account: before connecting, Home lists the cached conversations, which may be another account's.
    func loadPreview(_ id: ConversationID) async {
        guard !me.id.rawValue.isEmpty, let room = conversation(id) else { return }
        let last = history.messages.lazy.filter { $0.conversationID == id && !$0.isSystem }.map(\.createdAt).max()
        // A second of slack: the server's sort time can trail the message's own time by a little.
        if let last, (room.activity ?? .distantPast) <= last.addingTimeInterval(1) { return }
        await load(id, quietly: true)
    }
}
