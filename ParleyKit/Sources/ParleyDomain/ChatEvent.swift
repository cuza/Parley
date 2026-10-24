import Foundation

public enum ConnectionState: String, Codable, Sendable {
    case offline = "Offline"
    case connecting = "Connecting…"
    case connected = "Connected"
    case reconnecting = "Reconnecting…"
    case signedOut = "Signed out"
}
public enum ChatEvent: Sendable, Equatable {
    case messageUpserted(Message)
    case messageDeleted(MessageID)
    case conversationUpserted(Conversation)
    case conversationRemoved(ConversationID)  // removed: left, removed from, or deleted
    case readStateChanged(ConversationID, unread: Int)
    /// Read up to `at` here or on another device: what came before is read.
    case conversationViewed(ConversationID, at: Date)
    case threadViewed(ThreadID, at: Date)
    /// A thread marked unread, or the mark cleared, here or on another device.
    case threadMarkedUnread(ThreadID, Bool)
    /// A conversation marked unread on another device (here, `markUnread` already shows it).
    case conversationMarkedUnread(ConversationID)
    /// A conversation's count of followed threads with new replies changed.
    case unreadThreadsChanged(ConversationID, Int)
    /// The do not disturb schedules, changed here or on another device.
    case dndSchedulesChanged(DndSchedules)
    /// A conversation's sort time moved (a new message, here or elsewhere).
    case conversationActivity(ConversationID, at: Date)
    /// A DM's history cleared up to a time, here or on another device: older messages are gone for me.
    case historyCleared(ConversationID, upTo: Date)
    /// Google asks for Home's lists to be read again.
    case homeRefreshed
    /// Someone blocked or unblocked, here or on another device.
    case blocksChanged
    /// I started or stopped following a thread (here or elsewhere).
    case threadFollowChanged(ThreadID, following: Bool)
    /// Someone reacted to a message, or took it back, as pushed live (never replayed). `emoji` is a custom one's ":shortcode:".
    case reacted(MessageID, emoji: String, by: PersonID, added: Bool)
    /// Someone else started or stopped typing; `thread` set when they type in that thread's reply box.
    case typingChanged(ConversationID, ThreadID?, PersonID, isTyping: Bool)
    /// An agent (Ask Gemini) working in a thread, with its status ("Collecting info"); nil once it stopped.
    case activityChanged(ConversationID, ThreadID?, PersonID, label: String?)
    /// Readers' newest read times (never mine), merged per person; `enabled: false` turns receipts off and clears them.
    case readReceiptsChanged(ConversationID, [PersonID: Date], enabled: Bool?)
    /// nil presence: unchanged (a status push carries no active/away bit); `status` is the custom status, nil when none.
    case presenceChanged(PersonID, Presence?, status: String?)
    /// My own status, as read on connect or changed (here or on another device).
    case ownStatusChanged(OwnStatus)
    /// A server draft created or changed (here or on another device), or deleted (by its id).
    case draftChanged(ServerDraft)
    case draftDeleted(String)
    case connectionChanged(ConnectionState)
    case resync
}
