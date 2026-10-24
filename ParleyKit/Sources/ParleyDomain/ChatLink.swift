import Foundation

/// A link to a Google Chat conversation or message, as Google Chat writes them, so Parley can open it in place.
/// `chat.google.com/room/<space>[/<topic>[/<message>]]`, `/dm/<dm>[/…]`, `/app/chat/<id>` (space or DM: both are tried),
/// optionally after `/u/<n>`, with the message either as `/<topic>/<message>` or, as web Chat's address bar shows it,
/// `/topic/<topic>[/message/<message>]`, and Gmail's `mail.google.com/chat/…#chat/space/<id>` (or `#chat/dm/<id>`).
public struct ChatLink: Equatable, Sendable {
    public var conversations: [ConversationID]  // in order of preference; more than one when the link doesn't say which kind
    public var topic: String?
    public var message: String?

    public init?(_ url: URL) {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return nil }
        var parts: [String]
        switch host {
        case "chat.google.com": parts = url.pathComponents.filter { $0 != "/" }
        case "mail.google.com": parts = (url.fragment ?? "").split(separator: "/").map(String.init)
        default: return nil
        }
        if parts.first == "u", parts.count > 1 { parts.removeFirst(2) }
        if parts.first == "app" || parts.first == "chat" { parts.removeFirst() }
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "room", "space": conversations = [ConversationID("space/\(parts[1])")]
        case "dm": conversations = [ConversationID("dm/\(parts[1])")]
        case "chat": conversations = [ConversationID("space/\(parts[1])"), ConversationID("dm/\(parts[1])")]
        default: return nil
        }
        if parts.count >= 4, parts[2] == "topic" {
            parts = [parts[0], parts[1], parts[3]] + (parts.count >= 6 && parts[4] == "message" ? [parts[5]] : [])
        }
        if parts.count >= 3, !parts[2].isEmpty {
            topic = parts[2]
            message = parts.count >= 4 && !parts[3].isEmpty ? parts[3] : parts[2]
        }
    }
    init(conversations: [ConversationID], topic: String? = nil, message: String? = nil) {
        self.conversations = conversations
        self.topic = topic
        self.message = message
    }
    /// The link Google Chat copies for a message (`<conversation>/<topic>/<message>`); nil for an id that isn't one.
    public static func url(message id: MessageID) -> URL? {
        let parts = id.rawValue.split(separator: "/").map(String.init)
        guard parts.count == 4 else { return nil }
        return URL(
            string: "\(url(ConversationID("\(parts[0])/\(parts[1])")).absoluteString)/\(parts[2])/\(parts[3])?cls=10")
    }
    /// The link Google Chat uses for a conversation.
    public static func url(_ conversation: ConversationID) -> URL {
        let parts = conversation.rawValue.split(separator: "/", maxSplits: 1)
        let kind = parts.first == "dm" ? "dm" : "room"
        return URL(string: "https://chat.google.com/\(kind)/\(parts.last ?? "")")!
    }
}

extension ChatLink {
    /// Web's card for a conversation this account can't open (another account's, or one it isn't a member of).
    public var restrictedTitle: String {
        conversations.count == 1 && conversations[0].rawValue.hasPrefix("space/")
            ? "Restricted space" : "Restricted conversation"
    }
}
