import CryptoKit
import Foundation
import ParleyDomain

/// Domain IDs: conversation "space/<id>" | "dm/<id>"; message "<conversation>/<topic>/<message>".
enum DynamiteID {
    static func conversation(_ group: Dynamite_GroupId) -> ConversationID? {
        if !group.dmID.dmID.isEmpty { return ConversationID("dm/\(group.dmID.dmID)") }
        if !group.spaceID.spaceID.isEmpty { return ConversationID("space/\(group.spaceID.spaceID)") }
        return nil
    }
    static func group(_ id: ConversationID) throws -> Dynamite_GroupId {
        let parts = id.rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { throw DynamiteError.badID }
        switch parts[0] {
        case "dm": return .with { $0.dmID.dmID = String(parts[1]) }
        case "space": return .with { $0.spaceID.spaceID = String(parts[1]) }
        default: throw DynamiteError.badID
        }
    }
    /// Client-generated Dynamite message id: 8 bytes, base64url, no padding (11 chars), as Google Chat sends.
    /// Derived from the local id so every attempt at one draft sends the same id and Google rejects the repeat.
    static func messageID(for localID: String) -> String {
        Data(SHA256.hash(data: Data(localID.utf8)).prefix(8)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(
                of: "=", with: "")
    }
    static func message(_ conversation: ConversationID, topic: String, message: String) -> MessageID {
        MessageID("\(conversation.rawValue)/\(topic)/\(message)")
    }
    /// A pushed message's id, in the first of `groups` that names a conversation (events name it in more than one
    /// place); nil without a message id.
    static func message(_ id: Dynamite_MessageId, in groups: Dynamite_GroupId...) -> MessageID? {
        guard !id.messageID.isEmpty, let conversation = groups.lazy.compactMap(Self.conversation).first else {
            return nil
        }
        return message(conversation, topic: id.parentID.topicID.topicID, message: id.messageID)
    }
    /// A thread's id: the thread is named by its first message, whose id is the topic's.
    static func thread(_ conversation: ConversationID, topic: String) -> ThreadID {
        ThreadID(head: message(conversation, topic: topic, message: topic))
    }
    /// A thread's id from its topic; nil when the topic names no conversation.
    static func thread(_ topic: Dynamite_TopicId) -> ThreadID? {
        guard !topic.topicID.isEmpty, let conversation = Self.conversation(topic.groupID) else { return nil }
        return thread(conversation, topic: topic.topicID)
    }
    /// "space/x/t1/m1" → "space/x".
    static func conversation(of id: MessageID) -> ConversationID {
        ConversationID(id.rawValue.split(separator: "/").prefix(2).joined(separator: "/"))
    }
    static func conversation(of thread: ThreadID) -> ConversationID { conversation(of: thread.head) }
    static func protoMessageID(_ id: MessageID) throws -> Dynamite_MessageId {
        let parts = id.rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[2].isEmpty, !parts[3].isEmpty else { throw DynamiteError.badID }
        let group = try group(ConversationID("\(parts[0])/\(parts[1])"))
        return .with {
            $0.parentID.topicID.topicID = String(parts[2])
            $0.parentID.topicID.groupID = group
            $0.messageID = String(parts[3])
        }
    }
    static func topic(of id: MessageID) throws -> String {
        let parts = id.rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[2].isEmpty else { throw DynamiteError.badID }
        return String(parts[2])
    }
    /// A message's topic (a thread's, by its head) in its conversation, as requests about one thread name it.
    static func topicID(of id: MessageID, in conversation: ConversationID) throws -> Dynamite_TopicId {
        try .with {
            $0.topicID = try topic(of: id)
            $0.groupID = try group(conversation)
        }
    }
}
