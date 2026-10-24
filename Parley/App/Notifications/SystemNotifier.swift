import AppIntents
import AppKit
import ParleyDomain
import UserNotifications
import os

private let log = Logger(subsystem: "dev.cuza.Parley", category: "notifications")

/// UNUserNotificationCenter: banners grouped per conversation, a Reply text field, and clicks routed back to the store.
@MainActor final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    static let category = "message", replyAction = "reply"
    static let callCategory = "call", joinAction = "join", declineAction = "decline"
    private let store: ChatStore
    private var center: UNUserNotificationCenter { .current() }

    /// Set up before launch finishes so a click that launched the app still reaches the delegate.
    init(store: ChatStore) {
        self.store = store
        super.init()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        // An incoming call, as FaceTime offers one: Join opens the meeting; Decline dismisses it (Google isn't told).
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.callCategory, actions: [join, decline], intentIdentifiers: []),
        ])
        store.notifier = self
    }
    func post(_ notification: ChatNotification) {
        // macOS bounces only while Parley is in the background, and stops when it comes to the front.
        if UserDefaults.standard.bool(forKey: NotificationSettings.bounceKey) {
            NSApp.requestUserAttention(.informationalRequest)
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = NotificationSound.current.notificationSound
        content.threadIdentifier = notification.conversationID.rawValue
        content.categoryIdentifier = notification.isCall ? Self.callCategory : Self.category
        content.userInfo = [
            "conversation": notification.conversationID.rawValue, "thread": notification.threadID?.rawValue ?? "",
            "join": notification.join?.absoluteString ?? "",
        ]
        // "Reply to this" from a banner: Siri gets the message the banner shows.
        if #available(macOS 27, *) {
            content.appEntityIdentifiers = [EntityIdentifier(for: SiriMessage.self, identifier: notification.id)]
        }
        Task {
            let restyled = await NotificationImage.content(for: notification, base: content)
            let shown = (restyled.mutableCopy() as? UNMutableNotificationContent) ?? content
            shown.sound = content.sound  // the restyling would give a silent banner macOS's default sound
            do {
                try await center.add(UNNotificationRequest(identifier: notification.id, content: shown, trigger: nil))
                log.notice("banner posted")
                await Self.playSound()
            } catch {
                log.error(
                    "posting a notification failed: \(Redaction.redact(error.localizedDescription), privacy: .public)")
            }
        }
    }
    /// While Parley is in front: the banner, with macOS's sound only when macOS plays it (Default).
    nonisolated static func presentation(_ sound: NotificationSound) -> UNNotificationPresentationOptions {
        sound == .standard ? [.banner, .list, .sound] : [.banner, .list]
    }
    private static var playing: NSSound?
    /// A named sound, for a banner just posted, when NotificationSoundPolicy says so.
    private static func playSound() async {
        let sound = NotificationSound.current
        guard sound.playedByParley else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard NotificationSoundPolicy.plays(sound, soundsAllowed: settings.soundSetting == .enabled) else { return }
        playing?.stop()
        playing = sound.preview
        playing?.play()
    }
    func clear(conversation: ConversationID) {
        Task {
            let ids = await center.deliveredNotifications().filter {
                $0.request.content.threadIdentifier == conversation.rawValue
            }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
    // The store already skipped what is on screen, so anything posted shows even while the app is active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.presentation(NotificationSound.current)
    }
    // Async delegate methods arrive off the main thread: read the non-Sendable response here, then hop to the store.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let conversation = info["conversation"] as? String else { return }
        let thread = (info["thread"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let join = (info["join"] as? String).flatMap(URL.init(string:))
        await route(
            action: action, text: text, conversation: ConversationID(conversation), thread: thread.map { ThreadID($0) },
            join: join)
    }
    private func route(action: String, text: String?, conversation: ConversationID, thread: ThreadID?, join: URL?) async
    {
        switch action {
        case Self.replyAction: await store.reply(text ?? "", conversation: conversation, thread: thread)
        case Self.joinAction: if let join { NSWorkspace.shared.open(join) }
        case UNNotificationDefaultActionIdentifier:
            NSApplication.shared.activate()
            await store.open(conversation: conversation, thread: thread)
        default: break
        }
    }
}
