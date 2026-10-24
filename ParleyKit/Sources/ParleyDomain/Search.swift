import Foundation

/// A thread in a space's Threads list, as Google Chat's Active threads lists it.
public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public var head: Message
    public var replyCount: Int
    public var unreadCount: Int
    public var mentionsMe: Bool  // an unread reply mentions me or @all
    public var following: Bool
    public var lastReply: Date
    public var id: MessageID { head.id }
    public init(head: Message, replyCount: Int, unreadCount: Int, mentionsMe: Bool, following: Bool, lastReply: Date) {
        self.head = head
        self.replyCount = replyCount
        self.unreadCount = unreadCount
        self.mentionsMe = mentionsMe
        self.following = following
        self.lastReply = lastReply
    }
    public enum Filter: String, CaseIterable, Sendable {
        case following = "Following"
        case unread = "Unread"
        case mentions = "Mentions"
    }
    /// Every chosen filter must hold, as Google Chat combines them.
    public static func filtered(_ threads: [ThreadSummary], by filters: Set<Filter>) -> [ThreadSummary] {
        threads.filter { thread in
            filters.allSatisfy { filter in
                switch filter {
                case .following: thread.following
                case .unread: thread.unreadCount > 0
                case .mentions: thread.mentionsMe
                }
            }
        }
    }
}
public struct MessagePage: Sendable {
    public var messages: [Message]
    public var hasMore: Bool  // older history remains
    public var hasNewer = false  // a window away from the newest messages: newer history remains
    public init(messages: [Message], hasMore: Bool, hasNewer: Bool = false) {
        self.messages = messages
        self.hasMore = hasMore
        self.hasNewer = hasNewer
    }
}
/// A conversation's shared content, as the info panel's tabs group it.
public enum SharedCategory: String, CaseIterable, Sendable {
    case media = "Media"
    case files = "Files"
    case links = "Links"
}
public struct SharedPage: Sendable {
    public var items: [SharedContent.Item]
    public var hasMore: Bool
    public init(items: [SharedContent.Item], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}
public struct SearchPage: Sendable {
    public var messages: [Message]
    public var cursor: String?
    public init(messages: [Message], cursor: String? = nil) {
        self.messages = messages
        self.cursor = cursor
    }
}
/// Google Chat's search chips: From, a date range, Has, and Mentions me. Each narrows the results; within From or Has,
/// any choice matches.
public struct SearchFilters: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case link = "Link"
        case file = "Any file"
        case document = "Document"
        case spreadsheet = "Spreadsheet"
        case presentation = "Presentation"
        case image = "Image"
        case video = "Video"
        case pdf = "PDF"
    }
    /// The date chip's quick choices, as Google Chat offers them.
    public enum Age: String, CaseIterable, Sendable {
        case week = "Older than a week"
        case month = "Older than a month"
        case halfYear = "Older than 6 months"
        case year = "Older than a year"
        public func before(now: Date) -> Date {
            let days =
                switch self {
                case .week: 7
                case .month: 31
                case .halfYear: 182
                case .year: 365
                }
            return now.addingTimeInterval(-Double(days) * 86_400)
        }
    }
    public var from: [Person] = []
    public var saidIn: [ConversationID] = []  // "Said in": only these conversations
    public var after: Date?
    public var before: Date?
    public var has: Set<Kind> = []
    public var mentionsMe = false
    public var isEmpty: Bool { self == SearchFilters() }
    public init(
        from: [Person] = [], saidIn: [ConversationID] = [], after: Date? = nil, before: Date? = nil,
        has: Set<Kind> = [],
        mentionsMe: Bool = false
    ) {
        self.from = from
        self.saidIn = saidIn
        self.after = after
        self.before = before
        self.has = has
        self.mentionsMe = mentionsMe
    }
    /// Picks or drops a kind. Any file covers every file kind, so it and they exclude each other; a link is apart.
    public mutating func toggle(_ kind: Kind) {
        if has.remove(kind) != nil { return }
        if kind == .file { has = has.filter { $0 == .link } } else if kind != .link { has.remove(.file) }
        has.insert(kind)
    }
}
