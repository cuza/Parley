import AppKit
import ParleyDomain

/// What a row can ask for; the table owner supplies these, so the row never holds the store.
struct MessageRowActions {
    var react: (String, Message) -> Void = { _, _ in }
    var toggleTranscript: (Message) -> Void = { _ in }
    var dismissCard: (Message) -> Void = { _ in }  // a card's dismiss button (an app suggestion's "Don't install")
    var clickCard: (Message, String?, Data, [Card.Input]) async -> Void = { _, _, _, _ in }  // a card button's action
    var reactCustom: (CustomEmoji, Message) -> Void = { _, _ in }
    /// The organisation's custom emoji, which the picker offers; nil: none.
    var customEmoji: (() -> [CustomEmoji])?
    /// Who reacted, "Alice and You", for a reaction pill's hover card; nil: keep the count.
    var reactors: (Reaction, Message) async -> String? = { _, _ in nil }
    var openThread: (Message) -> Void = { _ in }
    var quote: (Message) -> Void = { _ in }  // a quote reply from this message's composer
    var forward: ((Message) -> Void)?  // Forward…: pick where it goes; nil: not offered
    var showQuoted: (MessageID) -> Void = { _ in }  // a click on a quote: go to the message it quotes
    var message: ((Person) -> Void)?  // "Message <Name>" from a sender's avatar or name, or a mention; nil: not offered
    var person: (PersonID) -> Person? = { _ in nil }  // who a mention names, for its card
    var cardDetails: ((Person) async -> PersonCardDetails)?  // a card's job title and local time; nil: not shown
    var showDetails: ((Person) -> Void)?  // "Show Details" on a card: the person's detailed view; nil: not offered
    /// Opens a Google Chat link from the text (a message link or a space chip) in Parley; false when the account doesn't
    /// have the conversation. Without an owner, it opens in the browser.
    var openChatLink: (ChatLink, URL) async -> Bool = { _, url in NSWorkspace.shared.open(url) }
    var retry: (Message) -> Void = { _ in }
    var copy: (Message) -> Void = { message in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
    var edit: (Message) -> Void = { _ in }
    var delete: (Message) -> Void = { _ in }
    /// Star or unstar (the new state); nil: not offered.
    var star: ((Bool, Message) -> Void)?
    /// Pin to the board or unpin (the new state); nil: not offered.
    var pin: ((Bool, Message) -> Void)?
    var markUnread: ((Message) -> Void)?  // Mark as Unread from this message on; nil: not offered
    var report: ((Message) -> Void)?  // Report this message (Workspace); nil: not offered
    /// Names of everyone whose read receipt covers the message, for "Seen by …" on my messages.
    var readers: (Message) -> [String] = { _ in [] }
    var loadAttachment: (Attachment, _ thumbnail: Bool) async throws -> Data = { _, _ in throw CancellationError() }
    /// Quick Look, drag out, and the attachment menu items; set by the table (`MessageTable`).
    var files: AttachmentFiles?
    /// Counts reactions made from the menu and the picker, which then offer the most used first; nil: the defaults.
    var emojiUsage: EmojiUsage?
}
