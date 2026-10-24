import Foundation
import ParleyDomain
import UserNotifications
import os

private let log = Logger(subsystem: "dev.cuza.Parley", category: "notifications")

/// Settings ▸ Notifications, stored with @AppStorage under `enabledKey`. Which messages notify is each conversation's level.
struct NotificationSettings: Equatable, Sendable {
    static let enabledKey = "notificationsEnabled"
    /// Bounce the Dock icon once per notification, as Slack offers it; off unless turned on.
    static let bounceKey = "bounceDockIcon"
    // ponytail: one switch covers messages and reactions to mine; add a per-kind toggle if reaction banners prove noisy.
    var enabled = true
    static var current: NotificationSettings {
        NotificationSettings(enabled: UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }
    /// Asks once the app is running: asked during launch, macOS showed no prompt and nothing was ever delivered.
    /// The system asks only the first time; later calls return the saved answer.
    @discardableResult
    static func requestAuthorization() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error(
                "notification authorization failed: \(Redaction.redact(error.localizedDescription), privacy: .public)")
        }
        return await center.notificationSettings().authorizationStatus
    }
}

/// What a banner shows and where clicking it leads. `id` is the message id, so a repeat replaces rather than stacks.
struct ChatNotification: Equatable, Sendable {
    var id: String  // the banner's: its message's id, or for a reaction the message's id, the reactor's and the emoji
    var title: String
    var subtitle: String
    var body: String
    var conversationID: ConversationID
    var threadID: ThreadID?
    var sender: Person
    /// The group DM's or space's name; nil for a 1:1 DM.
    var group: String?
    /// The sender's photo (a 1:1 DM without one falls back to the conversation's), else their initials.
    var picture: Picture
    /// An incoming call: the notification says so and offers to join the meeting or decline.
    var isCall = false
    var join: URL?
    func incomingCall(join url: URL?) -> ChatNotification {
        var call = self
        call.isCall = true
        call.join = url
        call.body = "Calling you"
        return call
    }

    struct Picture: Equatable, Sendable {
        var name: String
        var url: URL?
    }
}

enum NotificationPolicy {
    /// A pushed message's notification, or nil when it shouldn't interrupt: own, muted (even an @mention), edited, older than
    /// two minutes (an update to a message not loaded here), a text-less system event, below the conversation's level
    /// (unknown counts as every message), or already on screen. `threadFollowed`: the reply's thread is one I follow.
    /// `timelineShown`: the open conversation's own messages are on screen, not only its open thread (false on Home, whose
    /// thread pane opens in the conversation selected last).
    static func notification(
        for message: Message, in conversation: Conversation?, me: PersonID, openConversation: ConversationID?,
        openThread: ThreadID?, timelineShown: Bool = true, appActive: Bool, settings: NotificationSettings,
        threadFollowed: Bool = false,
        now: Date = .now
    ) -> ChatNotification? {
        guard settings.enabled, !message.isSystem, message.sender.id != me, !(conversation?.muted ?? false),
            !message.edited,
            message.createdAt > now.addingTimeInterval(-120), !message.text.isEmpty || !message.attachments.isEmpty,
            conversation?.notificationLevel?.notifies(
                head: message.threadID == nil, followed: message.threadID != nil && threadFollowed,
                mentioned: mentions(message, me: me)) ?? true
        else { return nil }
        let direct = conversation?.kind == .direct
        let onScreen =
            appActive && message.conversationID == openConversation
            && (message.threadID == nil ? timelineShown : message.threadID == openThread)
        guard !onScreen else { return nil }
        let gif =
            message.attachments.first.map {
                $0.contentType == "image/gif" || $0.url?.pathExtension.lowercased() == "gif"
            } ?? false
        return ChatNotification(
            id: message.id.rawValue, title: direct || conversation == nil ? message.sender.name : conversation!.name,
            subtitle: direct || conversation == nil ? "" : message.sender.name,
            body: !message.text.isEmpty
                ? TextStyleRange.plain(message.text, message.formatting)
                : gif
                    ? "GIF"
                    : message.attachments.first?.kind == .voice
                        ? "Voice message"
                        : message.attachments.first?.kind == .call ? message.attachments[0].name : "Sent an attachment",
            conversationID: message.conversationID, threadID: message.threadID, sender: message.sender,
            group: direct ? nil : conversation?.name,
            picture: .init(
                name: message.sender.name, url: message.sender.avatarURL ?? (direct ? conversation?.avatarURL : nil)))
    }
    /// Whether a message is someone's call to me, just started in a DM: Google posts it as the call rings. Not a huddle.
    static func isIncomingCall(_ message: Message, in conversation: Conversation?, me: PersonID, now: Date = .now)
        -> Bool
    {
        guard message.sender.id != me, conversation?.kind == .direct, message.createdAt > now.addingTimeInterval(-60),
            let call = message.attachments.first(where: { $0.kind == .call })
        else { return false }
        return call.call == .started && call.huddle != true
    }
    // Phase 2 (PARLEY-193): the tests call it with these labels; a context struct would change every call.
    /// Someone else's reaction to a message I sent, as Google Chat words it, or nil when it shouldn't interrupt: notifications
    /// off, the conversation muted or set to "Don't notify", or the message on screen. Removals and repeats are the caller's.
    static func reaction(  // swiftlint:disable:this function_parameter_count
        _ emoji: String, by reactor: Person, to message: Message, in conversation: Conversation?, me: PersonID,
        openConversation: ConversationID?, openThread: ThreadID?, timelineShown: Bool = true, appActive: Bool,
        settings: NotificationSettings
    ) -> ChatNotification? {
        guard settings.enabled, message.sender.id == me, reactor.id != me, !(conversation?.muted ?? false),
            conversation?.notificationLevel != .off
        else { return nil }
        let onScreen =
            appActive && message.conversationID == openConversation
            && (message.threadID == nil ? timelineShown : message.threadID == openThread)
        guard !onScreen else { return nil }
        let direct = conversation?.kind == .direct
        let text = TextStyleRange.plain(message.text, message.formatting).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let quote = text.count > 100 ? String(text.prefix(100)) + "…" : text
        return ChatNotification(
            id: "\(message.id.rawValue)#\(reactor.id.rawValue)#\(emoji)",
            title: direct || conversation == nil ? reactor.name : conversation!.name,
            subtitle: direct || conversation == nil ? "" : reactor.name,
            body: quote.isEmpty ? "Reacted \(emoji) to your message" : "Reacted \(emoji) to: “\(quote)”",
            conversationID: message.conversationID, threadID: message.threadID, sender: reactor,
            group: direct ? nil : conversation?.name,
            picture: .init(name: reactor.name, url: reactor.avatarURL ?? (direct ? conversation?.avatarURL : nil)))
    }
    /// Names me, or everyone with @all.
    static func mentions(_ message: Message, me: PersonID) -> Bool {
        message.formatting.contains {
            $0.style == .mention(userID: me) || $0.style == .mention(userID: TextStyleRange.everyone)
        }
    }
}

/// Where ChatStore posts notifications; tests record instead of showing banners.
@MainActor protocol Notifier: AnyObject {
    func post(_ notification: ChatNotification)
    /// Removes the conversation's delivered notifications (it was read).
    func clear(conversation: ConversationID)
}
