import Foundation

/// What the server lets me change in a space or group; nothing until it says.
public struct ConversationPermissions: Hashable, Sendable {
    public var editProfile = false  // name and emoji
    public var manageMembers = false  // add and remove people
    public var typing = true  // send a typing state; false where Google refuses it
    public var editDetails = false  // description and guidelines
    public var deleteSpace = false
    public var changeRoles = false  // make a member a manager, or back
    public var changeManagers = false  // change a manager's role
    public var toggleHistory = false
    public var reportMessages = false  // Workspace: report a message to the organisation's admin
    public var customEmoji: Bool?  // false where people outside the organisation take part; nil when not stated
    public init(
        editProfile: Bool = false, manageMembers: Bool = false, typing: Bool = true, editDetails: Bool = false,
        deleteSpace: Bool = false,
        changeRoles: Bool = false, changeManagers: Bool = false, toggleHistory: Bool = false,
        reportMessages: Bool = false,
        customEmoji: Bool? = nil
    ) {
        self.editProfile = editProfile
        self.manageMembers = manageMembers
        self.typing = typing
        self.editDetails = editDetails
        self.deleteSpace = deleteSpace
        self.changeRoles = changeRoles
        self.changeManagers = changeManagers
        self.toggleHistory = toggleHistory
        self.reportMessages = reportMessages
        self.customEmoji = customEmoji
    }
}
/// A sidebar section, as Google Chat keeps them for me: the default ones and the ones I made, in my order.
public struct SidebarSection: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Sendable {
        case directMessages = 1
        case spaces = 2
        case custom = 3
        case apps = 4
        case shortcuts = 5
    }
    public var kind: Kind
    public var key = ""  // a custom section's key (its conversations carry it); empty for the default ones
    public var name = ""
    public var position: Int  // its place among the sections
    public var id: String { kind == .custom ? key : "default-\(kind.rawValue)" }
    public init(kind: Kind, key: String = "", name: String = "", position: Int) {
        self.kind = kind
        self.key = key
        self.name = name
        self.position = position
    }
}
/// A space I blocked, as Google Chat's blocked list shows it.
public struct BlockedSpace: Identifiable, Hashable, Sendable {
    public let id: ConversationID
    public var name: String
    public init(id: ConversationID, name: String) {
        self.id = id
        self.name = name
    }
}
/// Why a message is reported, in Google Chat's words and order; the raw value is what Google receives.
public enum ReportReason: Int, CaseIterable, Sendable {
    case harassment = 1
    case discrimination = 2
    case explicitContent = 3
    case spam = 4
    case confidential = 5
    case sensitive = 7
    case other = 6
    public var title: String {
        switch self {
        case .harassment: "Harassment, offensive, or rude behavior"
        case .discrimination: "Discrimination or harmful stereotypes against anyone, including protected groups"
        case .explicitContent: "Explicit content that's graphic, violent, or otherwise inappropriate"
        case .spam: "Spam"
        case .confidential: "Confidential information"
        case .sensitive: "Sensitive information"
        case .other: "Something else"
        }
    }
}
/// A member's role in a space, as Google Chat names them.
public enum MemberRole: String, Codable, Sendable { case member, manager, owner }
/// A space from the directory, joined or not.
public struct SpaceListing: Identifiable, Hashable, Sendable {
    public let id: ConversationID
    public var name: String
    public var emoji: String?
    public var avatarURL: URL?
    var memberCount: Int?
    public var joined = false
    public var invited = false  // someone invited me; joining accepts
    public init(
        id: ConversationID, name: String, emoji: String? = nil, avatarURL: URL? = nil, memberCount: Int? = nil,
        joined: Bool = false,
        invited: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.avatarURL = avatarURL
        self.memberCount = memberCount
        self.joined = joined
        self.invited = invited
    }
    /// The line under its name in Browse spaces: "Invited · 3 members", "1 member".
    public static func detail(_ space: SpaceListing) -> String? {
        let members = space.memberCount.map { $0 == 1 ? "1 member" : "\($0) members" }
        return space.invited ? ["Invited", members].compactMap { $0 }.joined(separator: " · ") : members
    }
}
public enum ConversationKind: String, Codable, Sendable { case direct, group, space }
public struct Conversation: Identifiable, Hashable, Codable, Sendable {
    public let id: ConversationID
    public var name: String
    public var kind: ConversationKind
    public var members: [Person]
    public var unread: Int = 0
    public var unreadThreads: Int?  // followed threads with new replies, as Google Chat counts them: the sidebar shows it bold
    public var pinned = false
    public var muted = false
    public var emoji: String?  // a space's emoji icon; shown before avatarURL
    public var avatarURL: URL?  // space image, or the other person's photo in a 1:1 DM
    public var description: String?  // a space's description
    public var guidelines: String?  // a space's guidelines, shown under its description
    public var historyOff: Bool?  // history off: Google deletes new messages after a day; nil before the server says
    public var section: String?  // the key of the custom sidebar section I put it in, shared with the web
    public var notificationLevel: NotificationLevel?  // as Google Chat stores it for me; nil until the server reports it
    public var app: App?  // a 1:1 DM (`.direct`) with an app instead of a person
    public enum App: String, Codable, Sendable { case bot, gemini }  // gemini: Ask Gemini, a sidebar shortcut in Google Chat
    public var activity: Date?  // the server's last-activity time (its sidebar sort time), which Home orders by
    public var hidden: Date?  // when I hid it from my sidebar; listed in Settings ▸ Hidden conversations instead
    public var external: Bool?  // people outside my organisation take part; nil until the server says
    public init(
        id: ConversationID, name: String, kind: ConversationKind, members: [Person], unread: Int = 0,
        unreadThreads: Int? = nil,
        pinned: Bool = false, muted: Bool = false, emoji: String? = nil, avatarURL: URL? = nil,
        description: String? = nil,
        guidelines: String? = nil, historyOff: Bool? = nil, section: String? = nil,
        notificationLevel: NotificationLevel? = nil,
        app: App? = nil, activity: Date? = nil, hidden: Date? = nil, external: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.members = members
        self.unread = unread
        self.unreadThreads = unreadThreads
        self.pinned = pinned
        self.muted = muted
        self.emoji = emoji
        self.avatarURL = avatarURL
        self.description = description
        self.guidelines = guidelines
        self.historyOff = historyOff
        self.section = section
        self.notificationLevel = notificationLevel
        self.app = app
        self.activity = activity
        self.hidden = hidden
        self.external = external
    }
}
