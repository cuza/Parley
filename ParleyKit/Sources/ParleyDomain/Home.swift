import Foundation

/// A sidebar shortcut shown in place of a conversation, in the sidebar's order. Home lists conversations by recent
/// activity; Mentions and Starred list messages from every conversation; Drafts lists the unsent drafts.
public enum Shortcut: String, CaseIterable, Sendable {
    case home, mentions, starred, drafts
    public var title: String {
        switch self {
        case .home: "Home"
        case .mentions: "Mentions"
        case .starred: "Starred"
        case .drafts: "Drafts"
        }
    }
    public var icon: String {
        switch self {
        case .home: "house"
        case .mentions: "at"
        case .starred: "star"
        case .drafts: "doc"
        }
    }
}
/// A thread Home lists on a row of its own, beside its conversation's row: its first message and its newest reply.
public struct HomeThread: Identifiable, Hashable, Codable, Sendable {
    public let id: ThreadID  // the first message's id, as `Message.threadID` names it
    public var conversationID: ConversationID
    public var head: Message
    public var latest: Message  // the newest reply
    public var unread: Bool  // a reply from someone else I haven't read
    public var time: Date  // the server's sort time (its newest reply), which Home orders by
    public init(id: ThreadID, conversationID: ConversationID, head: Message, latest: Message, unread: Bool, time: Date)
    {
        self.id = id
        self.conversationID = conversationID
        self.head = head
        self.latest = latest
        self.unread = unread
        self.time = time
    }
}
/// One Home row: a conversation with its newest message, or (`thread` set) a thread with its newest reply.
public struct HomeRow: Identifiable, Hashable {
    public var room: Conversation
    public var last: Message?
    public var thread: HomeThread?
    public var time: Date
    public var id: String { thread?.id.rawValue ?? room.id.rawValue }  // a thread's or a conversation's, so plain text
    public var unread: Bool { thread?.unread ?? (room.unread > 0) }
    public init(room: Conversation, last: Message? = nil, thread: HomeThread? = nil, time: Date) {
        self.room = room
        self.last = last
        self.thread = thread
        self.time = time
    }
}
