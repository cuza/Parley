import Foundation

/// An identifier for one kind of thing, so passing a message id where a conversation id belongs doesn't compile.
/// It encodes as the plain string (also as a dictionary key) and prints as one, so caches, drafts and settings
/// saved while ids were strings read the same.
public struct ID<Tag>: RawRepresentable, Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible, CustomDebugStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
    public var debugDescription: String { rawValue.debugDescription }
}

public enum ConversationTag {}
public enum MessageTag {}
public enum ThreadTag {}
public enum PersonTag {}

public typealias ConversationID = ID<ConversationTag>
public typealias MessageID = ID<MessageTag>
public typealias ThreadID = ID<ThreadTag>
public typealias PersonID = ID<PersonTag>

extension ID where Tag == ThreadTag {
    /// Google Chat names a thread by its first message, so a thread's id is that message's id.
    public init(head: MessageID) { rawValue = head.rawValue }
    /// The thread's first message, whose id is the thread's.
    public var head: MessageID { MessageID(rawValue) }
}
