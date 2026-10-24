import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    /// The organisation's custom emoji as known now (the last launch's copy until this launch reads the list), starting
    /// that read if it hasn't started. For views that show the list as it arrives, such as the emoji picker.
    func customEmojiNow() -> [CustomEmoji] {
        // Read as a view draws: after a failed read, ask again at most every 30 seconds, not at each redraw.
        if lookups.shouldLoadCustomEmoji(at: .now) {
            lookups.customEmojiAsked = .now
            Task { await loadCustomEmoji() }
        }
        return lookups.customEmoji
    }
    /// Whether custom emoji can be used in `conversation`. Google Chat refuses them where people outside the organisation
    /// take part: a reaction answers HTTP 403, a message loses the emoji.
    /// The conversation's own capability where it was read (a space's or group's), its external mark until then.
    func allowsCustomEmoji(in conversation: ConversationID) -> Bool {
        rooms.permissions[conversation]?.customEmoji ?? (self.conversation(conversation)?.external != true)
    }
    /// Once a session, when a picker or the composer first needs them; a failure leaves the list empty and allows a retry.
    func loadCustomEmoji() async {
        if let running = lookups.customEmojiLoad { return await running.value }
        let load = Task {
            do {
                lookups.customEmoji = try await backend.customEmojis()
                persist()
            } catch {
                if case .http(403)? = error as? AuthFailure {  // personal accounts have none: don't ask again
                    log.notice("custom emoji: the list was refused (403); not asked again this launch")
                    return
                }
                lookups.customEmojiLoad = nil
                if (error as? AuthFailure)?.endsSession == true { report(error) }
            }
        }
        lookups.customEmojiLoad = load
        await load.value
    }
    /// Asks the server for the organisation's emoji matching `text` (what follows ":") and adds what's new to the list,
    /// so a large organisation's emoji show before (or without) the whole list. The latest query wins; a failure is ignored.
    func searchCustomEmoji(matching text: String) {
        lookups.customEmojiQuery = text
        coalesce("emoji-search") {
            guard let found = try? await self.backend.searchCustomEmoji(matching: self.lookups.customEmojiQuery) else {
                return
            }
            self.lookups.addCustomEmoji(found)
        }
    }
}
