import Foundation

/// A thread in its own window.
public struct ThreadRef: Codable, Hashable {
    public var conversation: ConversationID
    public var thread: ThreadID
    public init(conversation: ConversationID, thread: ThreadID) {
        self.conversation = conversation
        self.thread = thread
    }
}

public struct Message: Identifiable, Hashable, Codable, Sendable {
    public let id: MessageID
    public let conversationID: ConversationID
    public var threadID: ThreadID?
    public var sender: Person
    public var text: String
    public var createdAt: Date = .now
    public var edited = false
    public var reactions: [Reaction] = []
    public var delivery: Delivery = .sent
    public var replyCount = 0
    public var attachments: [Attachment] = []
    public var formatting: [TextStyleRange] = []
    public var quote: QuotedMessage?
    public var isSystem = false  // "Ana added Ben": a centered service line, not a bubble; `text` is the line
    public var lastUpdateMicros: Int64?  // the server's last update time, which a quote reply sends back
    public var via: String?  // the app that posted it on the sender's behalf (e.g. imported history), shown after the name
    public var following = false  // on a thread head: I follow the thread, as the server last said
    public var starred = false  // I starred it (Google Chat's per-user STAR label)
    public var sources: [Source] = []  // a Gemini answer's sources, listed under its text
    public var thinking: [ThinkingStep] = []  // the steps behind a Gemini answer ("Show thinking")
    public var translation: Translation?  // Google's translation for me; the timeline shows it first, `text` stays the original
    public var tombstone = false  // deleted, kept in its place as "Message deleted": nothing can be done with it, not even quote it
    public var pinned = false  // on the conversation's board, for everyone (Google Chat's PINNED label)
    public init(
        id: MessageID, conversationID: ConversationID, threadID: ThreadID? = nil, sender: Person, text: String,
        createdAt: Date = .now,
        edited: Bool = false, reactions: [Reaction] = [], delivery: Delivery = .sent, replyCount: Int = 0,
        attachments: [Attachment] = [],
        formatting: [TextStyleRange] = [], quote: QuotedMessage? = nil, isSystem: Bool = false,
        lastUpdateMicros: Int64? = nil,
        via: String? = nil, following: Bool = false, starred: Bool = false, sources: [Source] = [],
        thinking: [ThinkingStep] = [],
        translation: Translation? = nil, tombstone: Bool = false, pinned: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.threadID = threadID
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
        self.edited = edited
        self.reactions = reactions
        self.delivery = delivery
        self.replyCount = replyCount
        self.attachments = attachments
        self.formatting = formatting
        self.quote = quote
        self.isSystem = isSystem
        self.lastUpdateMicros = lastUpdateMicros
        self.via = via
        self.following = following
        self.starred = starred
        self.sources = sources
        self.thinking = thinking
        self.translation = translation
        self.tombstone = tombstone
        self.pinned = pinned
    }
}
public struct Reaction: Hashable, Codable, Sendable {
    public var emoji: String  // a custom emoji's is ":shortcode:"
    public var people: Set<PersonID>
    public var custom: CustomEmoji?
    public init(emoji: String, people: Set<PersonID>, custom: CustomEmoji? = nil) {
        self.emoji = emoji
        self.people = people
        self.custom = custom
    }
}
/// A Workspace organisation's own emoji. In `Message.text` it is one U+FFFD that a `.customEmoji` range covers.
public struct CustomEmoji: Hashable, Codable, Sendable {
    public var id: String
    public var shortcode: String  // without colons
    var imageURL: URL?  // fetched with `ChatBackend.attachmentData` (see `image`)
    public var deleted = false  // shown as ":shortcode:"
    public var payload = Data()  // the backend's own copy, sent back unchanged when reacting
    public var text: String { ":\(shortcode):" }
    /// The image as an attachment, so it loads through `ChatBackend.attachmentData` and `ImageCache` like other pictures.
    public var image: Attachment? {
        imageURL.map {
            Attachment(
                name: text, contentType: "image/png", kind: .image, thumbnailURL: $0, url: $0, width: 64, height: 64)
        }
    }
    public init(id: String, shortcode: String, imageURL: URL? = nil, deleted: Bool = false, payload: Data = Data()) {
        self.id = id
        self.shortcode = shortcode
        self.imageURL = imageURL
        self.deleted = deleted
        self.payload = payload
    }
}
public enum Delivery: String, Codable, Sendable { case pending, sent, failed }
/// A message as Google translated it for me (into my language), and the language it was written in.
public struct Translation: Hashable, Codable, Sendable {
    public var text: String
    public var formatting: [TextStyleRange] = []
    public var from: String  // a language tag ("es")
    public init(text: String, formatting: [TextStyleRange] = [], from: String) {
        self.text = text
        self.formatting = formatting
        self.from = from
    }
}
/// The message a quote reply quotes: as the server snapshotted it, or, on a reply being sent, the message it names.
public struct QuotedMessage: Hashable, Codable, Sendable {
    public var sender: String
    public var text: String
    public var id: MessageID?  // set only on a quote being sent
    public var lastUpdateMicros: Int64?  // the quoted message's `Message.lastUpdateMicros`, sent with `id`
    public var forwardedFrom: String?  // a forward, not a quote reply: the name of the conversation it came from
    public var media: Attachment?  // on a quote being sent: its first photo or video, for the composer's thumbnail
    public var emoji: [TextStyleRange]?  // its custom emoji, over their ":shortcode:" in `text`, drawn as pictures
    public init(
        sender: String, text: String, id: MessageID? = nil, lastUpdateMicros: Int64? = nil,
        forwardedFrom: String? = nil,
        media: Attachment? = nil, emoji: [TextStyleRange]? = nil
    ) {
        self.sender = sender
        self.text = text
        self.id = id
        self.lastUpdateMicros = lastUpdateMicros
        self.forwardedFrom = forwardedFrom
        self.media = media
        self.emoji = emoji
    }
    /// What a quote shows: the text, or for a message with none, what it carried, as web Chat names it.
    public static func summary(text: String, attachments: [Attachment]) -> String {
        guard text.isEmpty, let first = attachments.first else { return text }
        switch first.kind {
        case .image: return first.contentType == "image/gif" ? "GIF" : "Photo"
        case .video: return "Video"
        case .voice: return "Voice message"
        case .file, .link, .call, .card: return first.name
        }
    }
}
/// One step of a Gemini answer's reasoning, as Google Chat lists them under "Show thinking".
public struct ThinkingStep: Hashable, Codable, Sendable {
    public var title: String
    public var text: String
    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}
/// Something a Gemini answer drew on: an email, an event, a document… opened on the web.
public struct Source: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case gmail, calendar, docs, sheets, slides, drive, youtube, chat, tasks, web
    }
    public var title: String
    public var url: URL
    public var kind: Kind
    public var detail: String?  // a line from the source (its snippet, else its footer)
    public init(title: String, url: URL, kind: Kind, detail: String? = nil) {
        self.title = title
        self.url = url
        self.kind = kind
        self.detail = detail
    }
}
extension Message {
    /// Launch caches written before attachments or formatting existed lack those keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(MessageID.self, forKey: .id),
            conversationID: try container.decode(ConversationID.self, forKey: .conversationID),
            threadID: try container.decodeIfPresent(ThreadID.self, forKey: .threadID),
            sender: try container.decode(Person.self, forKey: .sender),
            text: try container.decode(String.self, forKey: .text),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            edited: try container.decode(Bool.self, forKey: .edited),
            reactions: try container.decode([Reaction].self, forKey: .reactions),
            delivery: try container.decode(Delivery.self, forKey: .delivery),
            replyCount: try container.decode(Int.self, forKey: .replyCount),
            attachments: try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [],
            formatting: try container.decodeIfPresent([TextStyleRange].self, forKey: .formatting) ?? [],
            quote: try container.decodeIfPresent(QuotedMessage.self, forKey: .quote),
            isSystem: try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false,
            lastUpdateMicros: try container.decodeIfPresent(Int64.self, forKey: .lastUpdateMicros),
            via: try container.decodeIfPresent(String.self, forKey: .via),
            following: try container.decodeIfPresent(Bool.self, forKey: .following) ?? false,
            starred: try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false,
            sources: try container.decodeIfPresent([Source].self, forKey: .sources) ?? [],
            thinking: try container.decodeIfPresent([ThinkingStep].self, forKey: .thinking) ?? [],
            translation: try container.decodeIfPresent(Translation.self, forKey: .translation),
            tombstone: try container.decodeIfPresent(Bool.self, forKey: .tombstone) ?? false,
            pinned: try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false)
    }
}

extension Message {
    /// How many emoji the message is when it is only one to three of them (custom ones too) and nothing else: drawn
    /// large and without a bubble, as Telegram and WhatsApp show them. Nil for any other message.
    public var jumboEmoji: Int? {
        guard attachments.isEmpty, quote == nil,
            formatting.allSatisfy({ if case .customEmoji = $0.style { $0.length == 1 } else { false } })
        else { return nil }
        let custom = Set(formatting.map(\.start))
        var count = 0
        var offset = 0  // UTF-16 offsets, as the formatting ranges count
        for character in text {
            defer { offset += character.utf16.count }
            if character.isWhitespace { continue }
            let emoji = character == "\u{FFFD}" ? custom.contains(offset) : character.isEmojiGlyph
            guard emoji else { return nil }
            count += 1
        }
        return (1...3).contains(count) ? count : nil
    }
}

extension Character {
    /// Drawn as an emoji: an emoji-style character, or one made emoji by a variation selector, skin tone or joiner.
    /// Digits, "#" and "©", which are emoji only with a selector, are not.
    public var isEmojiGlyph: Bool {
        guard let first = unicodeScalars.first?.properties else { return false }
        return first.isEmojiPresentation || (first.isEmoji && unicodeScalars.count > 1)
    }
}
