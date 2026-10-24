import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    var unreadCount: Int { rooms.conversations.filter { !$0.muted }.reduce(0) { $0 + $1.unread } }
    /// Home's threads with new replies, in conversations the sidebar lists and that aren't muted: Home's count.
    var unreadThreadCount: Int {  // read on every change to the conversations: the few unread threads are looked up, not the list
        rooms.homeThreads.filter { thread in
            thread.unread && rooms.conversations.contains { $0.id == thread.conversationID && !$0.muted }
        }.count
    }
    /// The Dock badge's number: the sidebar's unread messages and Home's unread threads.
    var badgeCount: Int { unreadCount + unreadThreadCount }
    /// The Dock menu's conversations: the unread ones the badge counts (not muted), most recent first, at most 10.
    var dockConversations: [Conversation] {
        Array(
            rooms.conversations.filter { $0.unread > 0 && !$0.muted }.sorted {
                ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast)
            }.prefix(10))
    }
    /// The Dock menu's Mark All as Read: every unread conversation, muted ones included.
    func markAllRead() async {
        let unread = rooms.conversations.filter { $0.unread > 0 }.map(\.id)
        let threads = rooms.homeThreads.filter(\.unread)
        // One change each, not one per conversation or thread: each change recounts the badge and redraws.
        rooms.conversations = rooms.conversations.map {
            var room = $0
            room.unread = 0
            return room
        }
        rooms.homeThreads = rooms.homeThreads.map {
            var thread = $0
            thread.unread = false
            return thread
        }  // as opening each from Home would
        persist()
        await withTaskGroup(of: Void.self) { group in
            for id in unread { group.addTask { await self.markRead(id) } }
            for thread in threads { group.addTask { await self.readThread(thread.id, upTo: thread.latest.createdAt) } }
        }
    }
    /// Siri's "mark this as read/unread": read clears the conversation; unread starts at the message, as its menu does.
    func setRead(_ read: Bool, _ message: Message) async {
        if read { await markRead(message.conversationID) } else { await markUnread(from: message) }
    }
    // ponytail: only threads Home lists unread; a reply while away in another open thread stays unread on the server.
    /// Back in Parley: the conversation and threads on screen are read, with what came while I was away.
    func appBecameActive() async {
        let threads = ([navigation.threadID] + navigation.panes.filter { $0.key != nil }.values.map(\.thread))
            .compactMap { $0 }
        for thread in threads where rooms.homeThreads.contains(where: { $0.id == thread && $0.unread }) {
            await readThread(thread)
        }
        guard let id = openConversation, !heldUnread.contains(id), let index = conversationIndex(id),
            rooms.conversations[index].unread > 0
        else { return }
        rooms.conversations[index].unread = 0
        await markRead(id)
    }
    func markRead(_ id: ConversationID) async {
        notifier?.clear(conversation: id)
        // In the background, and tried again on the next visit: a refusal is for the log, not an alert.
        do { try await backend.markRead(id) } catch {
            log.error("mark read failed: \(Redaction.redact(String(describing: error)), privacy: .public)")
        }
    }
    /// "Mark as unread" on a message: unread from it on, the conversation's, or for a reply its thread's on Home.
    func markUnread(from message: Message) async {
        if let thread = message.threadID {
            if let index = rooms.homeThreads.firstIndex(where: { $0.id == thread }) {
                rooms.homeThreads[index].unread = true
            }
            do { try await backend.markUnread(from: message) } catch { report(error) }
            return
        }
        let count = max(
            1,
            history.messages.filter {
                $0.conversationID == message.conversationID && $0.threadID == nil
                    && $0.createdAt >= message.createdAt && $0.sender.id != me.id
            }.count)
        heldUnread.insert(message.conversationID)
        let undoable = Undoable("Mark as Unread") { await self.markAsRead(message.conversationID) }
        await change(message.conversationID, \.unread, to: count, undoable: undoable) {
            try await self.backend.markUnread(from: message)
        }
    }
    func markUnread(_ id: ConversationID) async {
        guard let room = conversation(id) else { return }
        await change(
            id, \.unread, to: max(room.unread, 1), undoable: Undoable("Mark as Unread") { await self.markAsRead(id) }
        ) {
            try await self.backend.markUnread(id)
        }
    }
    /// The Mark as Read command: read at once, and Edit ▸ Undo marks it unread again. A refusal puts the count back and
    /// says why. `markRead` is the quiet one for conversations read by opening them.
    func markAsRead(_ id: ConversationID) async {
        notifier?.clear(conversation: id)
        heldUnread.remove(id)
        await change(id, \.unread, to: 0, undoable: Undoable("Mark as Read") { await self.markUnread(id) }) {
            try await self.backend.markRead(id)
        }
    }
}
