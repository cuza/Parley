import Foundation
import ParleyDomain

/// My conversations and what the server said about them: the sidebar's list and sections, the hidden ones, Home's threads,
/// members and their roles, what I may change, shared items, pinned boards, blocked people and invitations.
/// `ChatStore`'s actions load and change them through the backend; this model holds them.
@MainActor @Observable final class ConversationsModel {
    var conversations: [Conversation] = [] { didSet { listsChanged() } }
    /// Hidden from my sidebar (`Conversation.hidden`), for Settings ▸ Hidden conversations.
    var hidden: [Conversation] = []
    var homeThreads: [HomeThread] = [] { didSet { listsChanged() } }  // Home's thread rows, from the backend's last conversation list
    /// My sidebar sections, shared with the web, in my order; empty until Google sends them.
    var sections: [SidebarSection] = []
    var members: [ConversationID: [Person]] = [:]  // per conversation, from `ChatBackend.members(of:)`
    @ObservationIgnored var memberLoads: Set<ConversationID> = []
    /// Each member's role in a space, read with its members.
    var roles: [ConversationID: [PersonID: MemberRole]] = [:]
    var permissions: [ConversationID: ConversationPermissions] = [:]  // what I may change, once the server said
    /// The info panel's shared items from the server, per `sharedKey`; absent until loaded, or if the server refused.
    var shared: [String: [SharedContent.Item]] = [:]
    var sharedMore: Set<String> = []
    // The board: messages pinned for everyone in a conversation, as Google Chat's Board panel lists them.
    var pinned: [ConversationID: [Message]] = [:]
    /// People I blocked: their messages show as blocked, their DM leaves the sidebar.
    var blockedPeople: Set<PersonID> = []
    /// Spaces someone invited me to, from the space directory; joining one accepts it.
    var invitations: [SpaceListing] = []
    @ObservationIgnored var invitationsFetched: Date?
    /// Called when the conversations or Home's threads change: the Dock badge counts them.
    @ObservationIgnored var listsChanged: @MainActor () -> Void = {}

    /// The server's conversation list: the hidden ones apart, and Home's threads with it.
    func list(_ listed: [Conversation], threads: [HomeThread]) {
        conversations = listed.filter { $0.hidden == nil }
        hidden = listed.filter { $0.hidden != nil }
        homeThreads = threads
    }
    /// Removes a conversation that is gone, from the sidebar and from the hidden ones.
    func remove(_ id: ConversationID) {
        conversations.removeAll { $0.id == id }
        hidden.removeAll { $0.id == id }
    }
    /// Whether it is time to ask for invitations again: always when `force`d, else once `ttl` has passed.
    func invitationsDue(at time: Date, ttl: TimeInterval, force: Bool) -> Bool {
        force || invitationsFetched.map { time.timeIntervalSince($0) >= ttl } ?? true
    }
}
