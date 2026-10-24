import Foundation

/// When a conversation notifies me, as Google Chat stores it per person (the same setting web and mobile Chat show).
public enum NotificationLevel: String, Codable, Sendable {
    case always  // every message: a DM's "All new messages", an older space's "Notify always"
    case all  // every message, every thread followed: a space's "All new messages"
    case main  // new threads, replies in threads I follow, @mentions
    case forYouAndNewThreads  // older spaces: "For you" plus new threads
    case forYou  // @mentions and replies in threads I follow
    case off  // nothing, not even @mentions

    public var title: String {
        switch self {
        case .always, .all: "All new messages"
        case .main: "Main conversations"
        case .forYouAndNewThreads: "For you and new threads"
        case .forYou: "For you"
        case .off: "Don't notify"
        }
    }
    /// What the web offers: spaces get four levels, DMs notify or don't. A level set elsewhere stays pickable.
    public static func choices(for kind: ConversationKind, current: NotificationLevel?) -> [NotificationLevel] {
        var choices: [NotificationLevel] = kind == .space ? [.all, .main, .forYou, .off] : [.always, .off]
        if current == .always, let index = choices.firstIndex(of: .all) { choices[index] = .always }
        if let current, !choices.contains(current) { choices.append(current) }
        return choices
    }
    /// A message I didn't send: `head` starts a thread (every top-level message does), `followed` is a reply in a thread
    /// I follow, `mentioned` names me or @all.
    public func notifies(head: Bool, followed: Bool, mentioned: Bool) -> Bool {
        switch self {
        case .always, .all: true
        case .main, .forYouAndNewThreads: head || followed || mentioned
        case .forYou: followed || mentioned
        case .off: false
        }
    }
}
