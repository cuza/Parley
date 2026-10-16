import Foundation
import ImageIO
import UniformTypeIdentifiers

typealias ConversationID = String
typealias MessageID = String
typealias ThreadID = String
/// A thread in its own window.
struct ThreadRef: Codable, Hashable { var conversation: ConversationID; var thread: ThreadID }
typealias PersonID = String

/// The live value is `ChatStore.presence`; `Person.presence` is only the demo's and launch caches' copy.
enum Presence: String, Codable, Sendable { case available, away, offline, doNotDisturb }
/// My own status, as Google Chat's status menu sets it: automatic, away or Do Not Disturb (the server keeps only one),
/// and a custom status beside it.
struct OwnStatus: Equatable, Sendable {
    enum Availability: Equatable, Sendable { case automatic, away, doNotDisturb(until: Date) }
    var availability: Availability = .automatic
    var custom: CustomStatus? = nil
    /// Without a DND or custom status whose end has passed, before the server says it is over.
    func current(at now: Date) -> OwnStatus {
        var status = self
        if case .doNotDisturb(let until) = availability, until <= now { status.availability = .automatic }
        if let expires = custom?.expires, expires <= now { status.custom = nil }
        return status
    }
}
/// Recurring quiet periods that turn Do not disturb on by themselves, as Google Chat keeps them for the account.
struct DndSchedules: Equatable, Sendable {
    struct Period: Equatable, Sendable {
        var days: [Int]            // 1 Monday … 7 Sunday
        var start: Int             // minutes after midnight
        var end: Int               // before `start`: the period ends the next day; equal to it: all day
        var enabled = true
        var isAllDay: Bool { start == end }
        /// "Sun, Mon, Tue", in the week's order where it starts, or "Every day".
        func dayList(calendar: Calendar = .current) -> String {
            guard Set(days).count < 7 else { return "Every day" }
            let symbols = calendar.shortWeekdaySymbols   // Sunday first
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }   // indexes into `symbols`
            return order.filter { days.contains($0 == 0 ? 7 : $0) }.map { symbols[$0] }.joined(separator: ", ")
        }
    }
    var periods: [Period] = []
    var followsTimeZone = true     // the periods move with the Mac's time zone
    var timeZone = TimeZone.current.identifier
    static let limit = 7           // as Google Chat allows
}
struct CustomStatus: Equatable, Sendable {
    var text: String
    var emoji: String
    var expires: Date?
}
/// Google Chat's "Clear status after" choices.
enum CustomStatusExpiry: String, CaseIterable, Identifiable {
    case thirtyMinutes = "30 minutes", oneHour = "1 hour", fourHours = "4 hours", today = "Today", thisWeek = "This week"
    var id: Self { self }
    /// Today ends at the next midnight; the week at Monday's (Sunday night), whatever the locale's first weekday.
    func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .thirtyMinutes: now.addingTimeInterval(30 * 60)
        case .oneHour: now.addingTimeInterval(3600)
        case .fourHours: now.addingTimeInterval(4 * 3600)
        case .today: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .thisWeek: calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: 2), matchingPolicy: .nextTime)
        }
    }
}
struct Person: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var presence: Presence = .offline
    var avatarURL: URL? = nil   // public FIFE photo
    var email: String? = nil
}
extension Person {
    /// Someone known only by an email address: `ChatBackend.directMessage` invites them by email.
    static func invite(email: String) -> Person { Person(id: "email:" + email, name: email, email: email) }
    static func invitedEmail(_ id: PersonID) -> String? { id.hasPrefix("email:") ? String(id.dropFirst(6)) : nil }
}
/// What the server lets me change in a space or group; nothing until it says.
struct ConversationPermissions: Hashable, Sendable {
    var editProfile = false     // name and emoji
    var manageMembers = false   // add and remove people
    var typing = true           // send a typing state; false where Google refuses it
    var editDetails = false     // description and guidelines
    var deleteSpace = false
    var changeRoles = false     // make a member a manager, or back
    var changeManagers = false  // change a manager's role
    var toggleHistory = false
    var reportMessages = false  // Workspace: report a message to the organisation's admin
}
/// A sidebar section, as Google Chat keeps them for me: the default ones and the ones I made, in my order.
struct SidebarSection: Identifiable, Hashable, Sendable {
    enum Kind: Int, Sendable { case directMessages = 1, spaces = 2, custom = 3, apps = 4, shortcuts = 5 }
    var kind: Kind
    var key = ""          // a custom section's key (its conversations carry it); empty for the default ones
    var name = ""
    var position: Int     // its place among the sections
    var id: String { kind == .custom ? key : "default-\(kind.rawValue)" }
}
/// A space I blocked, as Google Chat's blocked list shows it.
struct BlockedSpace: Identifiable, Hashable, Sendable {
    let id: ConversationID
    var name: String
    var blocked: Date
}
/// Why a message is reported, in Google Chat's words and order; the raw value is what Google receives.
enum ReportReason: Int, CaseIterable, Sendable {
    case harassment = 1, discrimination = 2, explicitContent = 3, spam = 4, confidential = 5, sensitive = 7, other = 6
    var title: String {
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
enum MemberRole: String, Codable, Sendable { case member, manager, owner }
/// A space from the directory, joined or not.
struct SpaceListing: Identifiable, Hashable, Sendable {
    let id: ConversationID
    var name: String
    var emoji: String? = nil
    var avatarURL: URL? = nil
    var memberCount: Int? = nil
    var joined = false
    var invited = false   // someone invited me; joining accepts
    /// The line under its name in Browse spaces: "Invited · 3 members", "1 member".
    static func detail(_ space: SpaceListing) -> String? {
        let members = space.memberCount.map { $0 == 1 ? "1 member" : "\($0) members" }
        return space.invited ? ["Invited", members].compactMap { $0 }.joined(separator: " · ") : members
    }
}
enum ConversationKind: String, Codable, Sendable { case direct, group, space }
struct Conversation: Identifiable, Hashable, Codable, Sendable {
    let id: ConversationID
    var name: String
    var kind: ConversationKind
    var members: [Person]
    var unread: Int = 0
    var pinned = false
    var muted = false
    var emoji: String? = nil    // a space's emoji icon; shown before avatarURL
    var avatarURL: URL? = nil   // space image, or the other person's photo in a 1:1 DM
    var description: String? = nil   // a space's description
    var guidelines: String? = nil    // a space's guidelines, shown under its description
    var historyOff: Bool? = nil      // history off: Google deletes new messages after a day; nil before the server says
    var section: String? = nil       // the key of the custom sidebar section I put it in, shared with the web
    var notificationLevel: NotificationLevel? = nil   // as Google Chat stores it for me; nil until the server reports it
    var app: App? = nil   // a 1:1 DM (`.direct`) with an app instead of a person
    enum App: String, Codable, Sendable { case bot, gemini }   // gemini: Ask Gemini, a sidebar shortcut in Google Chat
    var activity: Date? = nil   // the server's last-activity time (its sidebar sort time), which Home orders by
    var hidden: Date? = nil     // when I hid it from my sidebar; listed in Settings ▸ Hidden conversations instead
}
struct Reaction: Hashable, Codable, Sendable {
    var emoji: String   // a custom emoji's is ":shortcode:"
    var people: Set<String>
    var custom: CustomEmoji? = nil
}
/// A Workspace organisation's own emoji. In `Message.text` it is one U+FFFD that a `.customEmoji` range covers.
struct CustomEmoji: Hashable, Codable, Sendable {
    var id: String
    var shortcode: String         // without colons
    var imageURL: URL? = nil      // fetched with `ChatBackend.attachmentData` (see `image`)
    var deleted = false           // shown as ":shortcode:"
    var payload = Data()          // the backend's own copy, sent back unchanged when reacting
    var text: String { ":\(shortcode):" }
    /// The image as an attachment, so it loads through `ChatBackend.attachmentData` and `ImageCache` like other pictures.
    var image: Attachment? {
        imageURL.map { Attachment(name: text, contentType: "image/png", kind: .image, thumbnailURL: $0, url: $0, width: 64, height: 64) }
    }
}
enum Delivery: String, Codable, Sendable { case pending, sent, failed }
/// An uploaded file or image, a Drive file, or a link preview. Bytes come from `ChatBackend.attachmentData`.
struct Attachment: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case image, video, file, link, voice, call, card }   // link: opens in the browser; voice: a recorded voice message; call: a Google Meet call; card: an app's card
    var name: String
    var contentType = ""
    var kind: Kind
    var thumbnailURL: URL? = nil
    var url: URL? = nil      // full size / download / page
    var width: Int? = nil    // known pixel size, so the timeline can reserve space
    var height: Int? = nil
    var snippet: String? = nil  // link preview description
    var domain: String? = nil   // set only on link previews, which render as a card
    var uploadToken: String? = nil   // opaque, from `ChatBackend.upload`: set on a local file once it is uploaded
    var voice: Voice? = nil          // set on `.voice`
    var call: CallStatus? = nil      // set on `.call`
    var huddle: Bool? = nil          // true on a huddle's `.call`, which never rings
    var cacheKey: String? = nil      // "<message id>#<place>": its picture's cache key, as its URL changes on every load
    var card: Card? = nil            // set on `.card`
    enum CallStatus: String, Codable, Sendable { case started, missed, ended, join }   // join: a Meet link
    /// Links and calls open in the browser; the rest preview with Quick Look.
    var opensInBrowser: Bool { kind == .link || kind == .call }
}
/// An app's card, read-only, as Google Chat draws it under the message: sections of items.
struct Card: Hashable, Codable, Sendable {
    var sections: [[Item]]
    enum Item: Hashable, Codable, Sendable {
        case text(String, [TextStyleRange], lines: Int? = nil)   // lines: cut to that many; nil: all
        /// A row with an optional icon (round: an avatar; `alt` says what it shows), a small label above, its text, and a
        /// button or a switch at its end.
        case row(icon: URL?, round: Bool, label: String?, text: String, formatting: [TextStyleRange], open: URL? = nil, button: Link? = nil,
                 toggle: Toggle? = nil, alt: String? = nil)   // open: a click on the row opens it
        case links([Link])
        case image(URL, aspect: Double, click: Link? = nil, alt: String? = nil)   // aspect: width over height; click: what a click does
        case divider
        case field(Field)       // a text field; its value goes with the card's actions
        case choice(Choice)     // check boxes, radio buttons, switches, a pop-up menu or a multiple choice
        case date(DateField)    // a date, a time or both
        /// Two columns side by side, stacked when the card is narrow (`CardLayout.sideBySide`).
        case columns([[Item]])
        /// A collapsible section's toggle, last in it: the `hidden` items before it show only once expanded.
        case collapse(more: String, less: String, hidden: Int)
    }
    /// The items of `section` drawn: a collapsed section without what it hides.
    static func shown(_ section: [Item], expanded: Bool) -> [Item] {
        guard !expanded, case .collapse(_, _, let hidden)? = section.last else { return section }
        var items = section
        items.removeSubrange(max(0, items.count - 1 - hidden)..<(items.count - 1))
        return items
    }
    /// What a card sends back with an action: one value of one of its inputs, by name. An input with several values
    /// (check boxes) sends one per value under the same name, as Google Chat does.
    struct Input: Hashable, Codable, Sendable { var name: String; var value: String }
    /// A text field: its label above, its hint (or what's wrong) under it.
    struct Field: Hashable, Codable, Sendable {
        var name: String, label: String, value: String
        var hint: String? = nil, placeholder: String? = nil
        var multiline: Bool? = nil
        var limit: Int? = nil       // characters at most
        var kind: Kind? = nil       // what it must hold; nil: any text
        var required: Bool? = nil   // an action needs it filled
        enum Kind: String, Codable, Sendable { case integer, number, email }
    }
    /// A selection input, its options with what each sends.
    struct Choice: Hashable, Codable, Sendable {
        var name: String, label: String?, style: Style, options: [Option]
        var limit: Int? = nil       // a multiple choice's most picks
        var required: Bool? = nil
        enum Style: String, Codable, Sendable { case checkbox, radio, switches, menu, multiple }
        struct Option: Hashable, Codable, Sendable { var text: String; var value: String; var selected: Bool; var detail: String? = nil }
    }
    /// A date or time picker; `ms` is the chosen moment (nil: none), shown in the viewer's time zone.
    struct DateField: Hashable, Codable, Sendable {
        var name: String, label: String?, kind: Kind, ms: Int64?
        var required: Bool? = nil
        enum Kind: Int, Codable, Sendable { case dateAndTime = 1, date = 2, time = 3 }   // Google Chat's numbers
    }
    /// A switch or check box at a row's end: `value` goes with the card's actions while it is on.
    struct Toggle: Hashable, Codable, Sendable { var name: String; var value: String; var on: Bool; var checkbox: Bool }
    /// Every item, columns' too, in order.
    var allItems: [Item] {
        func flat(_ items: [Item]) -> [Item] { items.flatMap { if case .columns(let columns) = $0 { [$0] + columns.flatMap(flat) } else { [$0] } } }
        return flat(sections.flatMap { $0 })
    }
    /// The card's inputs' values as they arrived, by name, in order (`CardView` keeps what is changed): a text field's
    /// even when empty, a choice's selected options, a switch only when on, a date when one is set.
    var form: [(name: String, values: [String])] {
        allItems.compactMap { item in
            switch item {
            case .field(let field): (field.name, [field.value])
            case .choice(let choice):
                (choice.name, choice.style == .menu || choice.style == .radio
                    ? [(choice.options.first(where: \.selected) ?? choice.options.first)?.value].compactMap { $0 }   // a pop-up always shows one
                    : choice.options.filter(\.selected).map(\.value))
            case .date(let date): (date.name, date.ms.map { [Self.dateValue($0, date.kind)] } ?? [])
            case .row(_, _, _, _, _, _, _, let toggle?, _): (toggle.name, toggle.on ? [toggle.value] : [])
            default: nil
            }
        }
    }
    /// What `form` sends: one input per value.
    var inputs: [Input] { form.flatMap { name, values in values.map { Input(name: name, value: $0) } } }
    /// A date's value as Google Chat's clients send it: a small JSON object.
    static func dateValue(_ ms: Int64, _ kind: DateField.Kind) -> String {
        #"{"dateTimeMS":"\#(ms)","hasDate":\#(kind != .time),"hasTime":\#(kind != .date),"type":\#(kind.rawValue)}"#
    }
    struct Link: Hashable, Codable, Sendable {
        var title: String; var url: URL
        var trailing: Bool? = nil   // set at the row's end (a button in an end-aligned column)
        var filled: Bool? = nil     // a filled button; otherwise outlined, as Google Chat draws a card's buttons
        var action: Data? = nil     // an action Parley sends (`ChatBackend.clickCard`); `url` is then the fallback
        var look: Look? = nil       // tonal or borderless; nil: `filled` decides
        var color: UInt32? = nil    // a filled button's own colour, ARGB
        var disabled: Bool? = nil   // drawn greyed, does nothing
        var symbol: String? = nil   // an SF Symbol before the title (alone on an icon button, whose title is empty)
        var icon: URL? = nil        // the icon as a picture, when no symbol stands for it
        var alt: String? = nil      // what the button does, for the tooltip and VoiceOver
        var menu: [MenuItem]? = nil // a click opens this menu instead
        var required: [String]? = nil   // inputs (by name) its action needs filled
        var dialog: Bool? = nil     // its action opens the app's dialog (`ChatBackend.dialog`) instead of acting in the card
        enum Look: String, Codable, Sendable { case tonal, borderless }
    }
    /// An overflow menu's item: its title, and what choosing it does.
    struct MenuItem: Hashable, Codable, Sendable { var title: String; var link: Link }
    /// The card's id in its message, which a click sends back (`click_card`); nil: none.
    var id: String? = nil
    /// The app's user id, which its dialogs' requests name; nil: not known.
    var app: String? = nil
    /// Every button and click in the card, in order: rows' end buttons, button rows, pictures' clicks, menus' items.
    var links: [Link] {
        allItems.flatMap { item -> [Link] in
            switch item {
            case .row(_, _, _, _, _, _, let button?, _, _): [button]
            case .links(let links): links
            case .image(_, _, let click?, _): [click]
            default: []
            }
        }.flatMap { [$0] + ($0.menu ?? []).map(\.link) }
    }
    /// Drawn without a box: the buttons an app puts under its message ("accessory widgets").
    var bare: Bool? = nil
    /// False: no line between its sections (the app draws its own dividers); nil: a line, as Google Chat draws by default.
    var dividers: Bool? = nil
    /// The app that made the card, shown under it as Google Chat does: "By <app>" and an App badge; nil: none.
    var by: Attribution? = nil
    struct Attribution: Hashable, Codable, Sendable { var name: String; var icon: URL? }
    /// A button that hides the card in Parley only (an app suggestion's "Don't install"); nil: none.
    var dismiss: String? = nil
    /// Grey for a card's small print, such as "Only visible to you": readable on light and dark.
    static let secondaryText: UInt32 = 0xFF80868B
}
/// An app's dialog, as Google Chat shows it over the conversation: a title, its card, and the buttons fixed at its bottom.
struct AppDialog: Hashable, Sendable {
    var title: String?              // the card's header; nil: the app's name
    var card: Card
    var primary: Card.Link? = nil   // the default button (Create, Submit)
    var secondary: Card.Link? = nil
}
/// Where a dialog belongs: the message it opened from (a slash command's own message for a command) and its app.
/// A quick command's dialog has no message: `message` is then its conversation, and `command` the command's id.
struct DialogContext: Hashable, Sendable {
    var message: MessageID
    var app: PersonID
    var command: Int64? = nil
}
/// A dialog's requests: open it (from a card's button, or with no action for a slash command), press one of its
/// buttons, or close it.
enum DialogStep: Sendable { case open, submit, cancel }
/// What an app answers.
enum DialogAnswer: Hashable, Sendable {
    case show(AppDialog)       // the dialog, or its next step in the same sheet
    case close(String?)        // done, with the app's note for a moment ("Poll started.")
    case invalid(String)       // stays open, saying what's wrong (empty: the app gave no reason)
    case configure(URL)        // the app needs setting up first, on its page in the browser
}
/// What a voice message carries besides its audio, as Google Chat sends it.
/// A message as Google translated it for me (into my language), and the language it was written in.
struct Translation: Hashable, Codable, Sendable {
    var text: String
    var formatting: [TextStyleRange] = []
    var from: String   // a language tag ("es")
}
struct Voice: Hashable, Codable, Sendable {
    var duration: TimeInterval
    var waveform: [Int] = []          // one 0…100 level per 100 ms; empty: computed from the audio once it loads
    var transcript: String? = nil     // the server's, once it has transcribed the message
    /// Google Chat names a recording after the time it was made.
    static func fileName(at date: Date = .now) -> String { "UserRecording_\(Int64((date.timeIntervalSince1970 * 1000).rounded())).m4a" }
    /// Google Chat labels its AAC recordings this way.
    static let contentType = "audio/mpeg"
}
/// A style over part of `Message.text`, in UTF-16 units (`NSRange` offsets).
struct TextStyleRange: Hashable, Codable, Sendable {
    enum Style: Hashable, Codable, Sendable {
        case bold, italic, strike, underline, code, codeBlock, listItem, heading, quote
        case small   // a card's small print (a bottom label): smaller type
        case nowrap  // its paragraph stays on one line, cut with "…" (a card row that doesn't wrap)
        case list(level: Int, number: Int?)   // a nested (level 1…4) or numbered list item; a plain one is `listItem`
        case mention(userID: String?)   // the mentioned user; nil in launch caches written before it was kept
        case link(URL)
        case customEmoji(CustomEmoji)   // over the one U+FFFD that stands for it
        case color(UInt32)              // text colour, ARGB, as Google Chat stores it
        // A space or DM chip over its name: the space's emoji when known, and the link it was made from (a message's, maybe).
        case chip(ConversationID, emoji: String? = nil, link: URL? = nil)
        case slashCommand(SlashCommand)   // over a picked command's name at the start: the message invokes it
    }
    var style: Style
    var start: Int
    var length: Int
    /// The user id an @all mention carries.
    static let everyone = "@all"
    /// `text` with each custom emoji written as ":shortcode:", for places that show plain text (quotes, notifications).
    /// `plain`, with where each custom emoji's ":shortcode:" ended up, for text that draws them as pictures.
    static func plainWithEmoji(_ text: String, _ formatting: [TextStyleRange]) -> (text: String, emoji: [TextStyleRange]) {
        let plain = NSMutableString(string: text)
        var emoji: [TextStyleRange] = [], shift = 0
        for range in formatting.sorted(by: { $0.start < $1.start }) where range.start >= 0 && range.start + range.length <= (text as NSString).length {
            guard case .customEmoji(let custom) = range.style else { continue }
            let at = NSRange(location: range.start + shift, length: range.length), code = custom.text as NSString
            plain.replaceCharacters(in: at, with: code as String)
            emoji.append(TextStyleRange(style: range.style, start: at.location, length: code.length))
            shift += code.length - range.length
        }
        return (plain as String, emoji)
    }
    static func plain(_ text: String, _ formatting: [TextStyleRange]) -> String {
        let plain = NSMutableString(string: text)
        for range in formatting.sorted(by: { $0.start > $1.start }) where range.start >= 0 && range.start + range.length <= plain.length {
            if case .customEmoji(let emoji) = range.style { plain.replaceCharacters(in: NSRange(location: range.start, length: range.length), with: emoji.text) }
        }
        return plain as String
    }
}
/// The text colours Google Chat's composer offers, with the ARGB values it sends; light and dark alike.
enum TextColor: CaseIterable, Sendable {
    case red, blue, green, amber, grey
    var argb: UInt32 {
        switch self { case .red: 0xFFF4_4336; case .blue: 0xFF21_96F3; case .green: 0xFF4C_AF50; case .amber: 0xFFFF_C107; case .grey: 0xFF9E_9E9E }
    }
    var name: String { "\(self)".capitalized }
}
/// The message a quote reply quotes: as the server snapshotted it, or, on a reply being sent, the message it names.
struct QuotedMessage: Hashable, Codable, Sendable {
    var sender: String
    var text: String
    var id: MessageID? = nil              // set only on a quote being sent
    var lastUpdateMicros: Int64? = nil    // the quoted message's `Message.lastUpdateMicros`, sent with `id`
    var forwardedFrom: String? = nil      // a forward, not a quote reply: the name of the conversation it came from
    var media: Attachment? = nil          // on a quote being sent: its first photo or video, for the composer's thumbnail
    var emoji: [TextStyleRange]? = nil    // its custom emoji, over their ":shortcode:" in `text`, drawn as pictures
    /// What a quote shows: the text, or for a message with none, what it carried, as web Chat names it.
    static func summary(text: String, attachments: [Attachment]) -> String {
        guard text.isEmpty, let first = attachments.first else { return text }
        switch first.kind {
        case .image: return first.contentType == "image/gif" ? "GIF" : "Photo"
        case .video: return "Video"
        case .voice: return "Voice message"
        case .file, .link, .call, .card: return first.name
        }
    }
}
struct Message: Identifiable, Hashable, Codable, Sendable {
    let id: MessageID
    let conversationID: ConversationID
    var threadID: ThreadID? = nil
    var sender: Person
    var text: String
    var createdAt: Date = .now
    var edited = false
    var reactions: [Reaction] = []
    var delivery: Delivery = .sent
    var replyCount = 0
    var attachments: [Attachment] = []
    var formatting: [TextStyleRange] = []
    var quote: QuotedMessage? = nil
    var isSystem = false   // "Ana added Ben": a centered service line, not a bubble; `text` is the line
    var lastUpdateMicros: Int64? = nil   // the server's last update time, which a quote reply sends back
    var via: String? = nil   // the app that posted it on the sender's behalf (e.g. imported history), shown after the name
    var following = false    // on a thread head: I follow the thread, as the server last said
    var starred = false      // I starred it (Google Chat's per-user STAR label)
    var sources: [Source] = []   // a Gemini answer's sources, listed under its text
    var thinking: [ThinkingStep] = []   // the steps behind a Gemini answer ("Show thinking")
    var translation: Translation? = nil   // Google's translation for me; the timeline shows it first, `text` stays the original
    var tombstone = false    // deleted, kept in its place as "Message deleted": nothing can be done with it, not even quote it
    var pinned = false       // on the conversation's board, for everyone (Google Chat's PINNED label)
}
/// One step of a Gemini answer's reasoning, as Google Chat lists them under "Show thinking".
struct ThinkingStep: Hashable, Codable, Sendable {
    var title: String
    var text: String
}
/// Something a Gemini answer drew on: an email, an event, a document… opened on the web.
struct Source: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case gmail, calendar, docs, sheets, slides, drive, youtube, chat, tasks, web }
    var title: String
    var url: URL
    var kind: Kind
    var detail: String? = nil   // a line from the source (its snippet, else its footer)
}
extension Message {
    /// Launch caches written before attachments or formatting existed lack those keys.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(MessageID.self, forKey: .id), conversationID: try c.decode(ConversationID.self, forKey: .conversationID),
                  threadID: try c.decodeIfPresent(ThreadID.self, forKey: .threadID), sender: try c.decode(Person.self, forKey: .sender),
                  text: try c.decode(String.self, forKey: .text), createdAt: try c.decode(Date.self, forKey: .createdAt),
                  edited: try c.decode(Bool.self, forKey: .edited), reactions: try c.decode([Reaction].self, forKey: .reactions),
                  delivery: try c.decode(Delivery.self, forKey: .delivery), replyCount: try c.decode(Int.self, forKey: .replyCount),
                  attachments: try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [],
                  formatting: try c.decodeIfPresent([TextStyleRange].self, forKey: .formatting) ?? [],
                  quote: try c.decodeIfPresent(QuotedMessage.self, forKey: .quote),
                  isSystem: try c.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false,
                  lastUpdateMicros: try c.decodeIfPresent(Int64.self, forKey: .lastUpdateMicros),
                  via: try c.decodeIfPresent(String.self, forKey: .via),
                  following: try c.decodeIfPresent(Bool.self, forKey: .following) ?? false,
                  starred: try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false,
                  sources: try c.decodeIfPresent([Source].self, forKey: .sources) ?? [],
                  thinking: try c.decodeIfPresent([ThinkingStep].self, forKey: .thinking) ?? [],
                  translation: try c.decodeIfPresent(Translation.self, forKey: .translation),
                  tombstone: try c.decodeIfPresent(Bool.self, forKey: .tombstone) ?? false,
                  pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false)
    }
}
struct MessageDraft: Sendable {
    var text: String; var localID: String; var formatting: [TextStyleRange] = []
    var uploads: [Attachment] = []   // files already uploaded with `ChatBackend.upload` (each has an `uploadToken`)
    var quoting: QuotedMessage? = nil   // a quote reply: the quoted message, with its `id` and `lastUpdateMicros`
    var serverDraftID: String? = nil    // the server draft this message was, which the server drops on send
}
/// A composer's draft as Google Chat keeps it on the server, so it follows the user between devices.
struct ServerDraft: Hashable, Codable, Sendable {
    var id = ""                       // empty until first saved; the backend names it then
    var conversationID: ConversationID
    var threadID: ThreadID? = nil     // a thread's reply box has a draft of its own
    var text: String
    var formatting: [TextStyleRange] = []
    var updatedAt: Date = .now        // the server's last update time
    var schedule: Schedule? = nil     // a scheduled message: Google sends it at this time; nil for a composer's draft
    struct Schedule: Hashable, Codable, Sendable {
        var at: Date
        var failed = false            // Google tried at that time and couldn't send it
    }
}
/// A thread in a space's Threads list, as Google Chat's Active threads lists it.
struct ThreadSummary: Identifiable, Hashable, Sendable {
    var head: Message
    var replyCount: Int
    var unreadCount: Int
    var mentionsMe: Bool      // an unread reply mentions me or @all
    var following: Bool
    var lastReply: Date
    var id: MessageID { head.id }
    enum Filter: String, CaseIterable, Sendable { case following = "Following", unread = "Unread", mentions = "Mentions" }
    /// Every chosen filter must hold, as Google Chat combines them.
    static func filtered(_ threads: [ThreadSummary], by filters: Set<Filter>) -> [ThreadSummary] {
        threads.filter { thread in
            filters.allSatisfy { filter in
                switch filter {
                case .following: thread.following
                case .unread: thread.unreadCount > 0
                case .mentions: thread.mentionsMe
                }
            }
        }
    }
}
struct MessagePage: Sendable {
    var messages: [Message]
    var hasMore: Bool          // older history remains
    var hasNewer = false       // a window away from the newest messages: newer history remains
}
/// A conversation's shared content, as the info panel's tabs group it.
enum SharedCategory: String, CaseIterable, Sendable { case media = "Media", files = "Files", links = "Links" }
struct SharedPage: Sendable { var items: [SharedContent.Item]; var hasMore: Bool }
struct SearchPage: Sendable { var messages: [Message]; var cursor: String? = nil }
/// Google Chat's search chips: From, a date range, Has, and Mentions me. Each narrows the results; within From or Has,
/// any choice matches.
/// Search asked for from outside the window (Shortcuts, Siri): the panel opens with these words.
struct SearchRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let query: String
}
struct SearchFilters: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case link = "Link", file = "Any file", document = "Document", spreadsheet = "Spreadsheet", presentation = "Presentation"
        case image = "Image", video = "Video", pdf = "PDF"
    }
    /// The date chip's quick choices, as Google Chat offers them.
    enum Age: String, CaseIterable, Sendable {
        case week = "Older than a week", month = "Older than a month", halfYear = "Older than 6 months", year = "Older than a year"
        func before(now: Date) -> Date {
            let days = switch self { case .week: 7; case .month: 31; case .halfYear: 182; case .year: 365 }
            return now.addingTimeInterval(-Double(days) * 86_400)
        }
    }
    var from: [Person] = []
    var saidIn: [ConversationID] = []   // "Said in": only these conversations
    var after: Date? = nil
    var before: Date? = nil
    var has: Set<Kind> = []
    var mentionsMe = false
    var isEmpty: Bool { self == SearchFilters() }
    /// Picks or drops a kind. Any file covers every file kind, so it and they exclude each other; a link is apart.
    mutating func toggle(_ kind: Kind) {
        if has.remove(kind) != nil { return }
        if kind == .file { has = has.filter { $0 == .link } } else if kind != .link { has.remove(.file) }
        has.insert(kind)
    }
}
/// A sidebar shortcut shown in place of a conversation, in the sidebar's order. Home lists conversations by recent
/// activity; Mentions and Starred list messages from every conversation; Drafts lists the unsent drafts.
enum Shortcut: String, CaseIterable, Sendable {
    case home, mentions, starred, drafts
    var title: String { switch self { case .home: "Home"; case .mentions: "Mentions"; case .starred: "Starred"; case .drafts: "Drafts" } }
    var icon: String { switch self { case .home: "house"; case .mentions: "at"; case .starred: "star"; case .drafts: "doc" } }
}
/// Settings ▸ General's "At launch, open": Home, as Google Chat opens, or the conversation open at the last quit, as
/// Mail and Messages reopen.
enum LaunchLanding: String, CaseIterable {
    case home, last
    static let key = "launchLanding"
    static var current: LaunchLanding { UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .home }
    var shortcut: Shortcut? { self == .home ? .home : nil }
}
/// A thread Home lists on a row of its own, beside its conversation's row: its first message and its newest reply.
struct HomeThread: Identifiable, Hashable, Codable, Sendable {
    let id: ThreadID                  // the first message's id, as `Message.threadID` names it
    var conversationID: ConversationID
    var head: Message
    var latest: Message               // the newest reply
    var unread: Bool                  // a reply from someone else I haven't read
    var time: Date                    // the server's sort time (its newest reply), which Home orders by
}
/// One Home row: a conversation with its newest message, or (`thread` set) a thread with its newest reply.
struct HomeRow: Identifiable, Hashable {
    var room: Conversation
    var last: Message?
    var thread: HomeThread? = nil
    var time: Date
    var id: String { thread?.id ?? room.id }
    var unread: Bool { thread?.unread ?? (room.unread > 0) }
}
enum ConnectionState: String, Codable, Sendable {
    case offline = "Offline", connecting = "Connecting…", connected = "Connected", reconnecting = "Reconnecting…", signedOut = "Signed out"
}
enum ChatEvent: Sendable, Equatable {
    case messageUpserted(Message), messageDeleted(MessageID)
    case conversationUpserted(Conversation), conversationRemoved(ConversationID)   // removed: left, removed from, or deleted
    case readStateChanged(ConversationID, unread: Int)
    /// I started or stopped following a thread (here or elsewhere).
    case threadFollowChanged(ThreadID, following: Bool)
    /// Someone reacted to a message, or took it back, as pushed live (never replayed). `emoji` is a custom one's ":shortcode:".
    case reacted(MessageID, emoji: String, by: PersonID, added: Bool)
    /// Someone else started or stopped typing; `thread` set when they type in that thread's reply box.
    case typingChanged(ConversationID, ThreadID?, String, isTyping: Bool)
    /// An agent (Ask Gemini) working in a thread, with its status ("Collecting info"); nil once it stopped.
    case activityChanged(ConversationID, ThreadID?, String, label: String?)
    /// Readers' newest read times (never mine), merged per person; `enabled: false` turns receipts off and clears them.
    case readReceiptsChanged(ConversationID, [String: Date], enabled: Bool?)
    /// nil presence: unchanged (a status push carries no active/away bit); `status` is the custom status, nil when none.
    case presenceChanged(String, Presence?, status: String?)
    /// My own status, as read on connect or changed (here or on another device).
    case ownStatusChanged(OwnStatus)
    /// A server draft created or changed (here or on another device), or deleted (by its id).
    case draftChanged(ServerDraft), draftDeleted(String)
    case connectionChanged(ConnectionState)
    case resync
}
protocol ChatBackend: Sendable {
    var events: AsyncStream<ChatEvent> { get }
    /// Verifies the session and returns the signed-in person.
    func connect() async throws -> Person
    func conversations() async throws -> [Conversation]
    func messages(in conversation: ConversationID, thread: ThreadID?, before: Date?) async throws -> MessagePage
    /// The page around `message`, as web Chat opens an old search result; older pages follow with `messages(in:before:)`.
    func messages(around message: MessageID, in conversation: ConversationID) async throws -> MessagePage
    /// A space's threads with replies, newest reply first, as Google Chat's Active threads lists them; the list is then
    /// marked seen.
    func threads(in conversation: ConversationID) async throws -> [ThreadSummary]
    /// The next page after the newest one loaded since `messages(around:in:)`.
    func newerMessages(in conversation: ConversationID) async throws -> MessagePage
    func send(_ draft: MessageDraft, to conversation: ConversationID, thread: ThreadID?) async throws -> Message
    /// Makes a Google Meet meeting for the conversation and posts it, as Google Chat's "Send a Meet link" does.
    func sendMeetLink(in conversation: ConversationID) async throws -> Message
    func edit(_ id: MessageID, text: String, formatting: [TextStyleRange]) async throws
    func delete(_ id: MessageID) async throws
    /// `custom`: the reaction's custom emoji, which goes back to the server as it came.
    func setReaction(_ emoji: String, custom: CustomEmoji?, on id: MessageID, present: Bool) async throws
    /// Everyone who reacted to a message with `emoji`, as the server lists them (up to 100).
    func reactors(of id: MessageID, emoji: String, custom: CustomEmoji?) async throws -> [Person]
    func markRead(_ conversation: ConversationID) async throws
    /// Marks a thread read up to its newest reply, so it reads as read on every device.
    func markThreadRead(_ thread: ThreadID, upTo time: Date) async throws
    /// Follows a thread (its replies notify me) or unfollows it.
    func setFollowing(_ following: Bool, thread: ThreadID) async throws
    /// Marks the newest message unread until the conversation is read again.
    func markUnread(_ conversation: ConversationID) async throws
    /// Marks a conversation, or for a reply its thread, unread from that message on.
    func markUnread(from message: Message) async throws
    /// Pins (stars) a conversation in my sidebar, or unpins it.
    func setPinned(_ pinned: Bool, conversation: ConversationID) async throws
    /// Mutes a conversation's notifications, or unmutes them; the notification level stays as it was.
    func setMuted(_ muted: Bool, conversation: ConversationID) async throws
    /// Sets when a conversation notifies me; `muted` is resent as it is, since the server stores both together.
    func setNotificationLevel(_ level: NotificationLevel, muted: Bool, conversation: ConversationID) async throws
    /// Leaves a space or group conversation.
    func leave(_ conversation: ConversationID) async throws
    /// What I may change in a space or group.
    func permissions(in conversation: ConversationID) async throws -> ConversationPermissions
    /// Renames a space or group and/or sets its emoji; nil leaves that one as it is.
    func updateProfile(_ conversation: ConversationID, name: String?, emoji: String?) async throws
    /// Adds people to a space or group; a space invites them.
    func addMembers(_ people: [PersonID], to conversation: ConversationID) async throws
    /// Removes someone else from a space or group.
    func removeMember(_ person: PersonID, from conversation: ConversationID) async throws
    /// Hides a conversation from my sidebar, or shows it again.
    func setHidden(_ hidden: Bool, conversation: ConversationID) async throws
    /// A new space with me as its only member, as Google Chat's Create a space makes it.
    func createSpace(name: String, emoji: String?) async throws -> Conversation
    /// Deletes a space and all its messages for everyone.
    func deleteSpace(_ conversation: ConversationID) async throws
    /// The sidebar's sections from the last `conversations()` read, in my order (empty when Google sent none).
    func sidebarSections() async -> [SidebarSection]
    func createSection(named name: String, at position: Int) async throws -> SidebarSection
    func renameSection(_ section: SidebarSection, to name: String) async throws
    func moveSection(_ section: SidebarSection, to position: Int) async throws
    func deleteSection(_ section: SidebarSection) async throws
    /// Moves a conversation into a custom section (its key), or back to its default one (nil), from `previous`.
    func moveConversation(_ conversation: ConversationID, to section: String?, from previous: String?) async throws
    /// Blocks or unblocks a person (and their DM with me), optionally reporting them to Google.
    func setBlocked(_ blocked: Bool, person: PersonID, dm: ConversationID?, report: Bool) async throws
    /// Blocks or unblocks a space, optionally reporting it to Google.
    func setBlocked(_ blocked: Bool, space: ConversationID, report: Bool) async throws
    func blockedPeople() async throws -> [PersonID]
    func blockedSpaces() async throws -> [BlockedSpace]
    /// Reports a message to the organisation's admin.
    func report(_ message: Message, reason: ReportReason, explanation: String) async throws
    /// A space's description and guidelines, saved together as Google Chat saves them.
    func updateDetails(_ conversation: ConversationID, description: String, guidelines: String) async throws
    func setRole(_ role: MemberRole, of person: PersonID, in conversation: ConversationID) async throws
    /// History on keeps messages; off has Google delete new ones after a day.
    func setHistory(_ on: Bool, in conversation: ConversationID) async throws
    /// Each member's role, from the last `members(of:)` read.
    func roles(in conversation: ConversationID) async -> [PersonID: MemberRole]
    /// Messages matching `query`, in every conversation or only `conversation`.
    func searchMessages(_ query: String, filters: SearchFilters, cursor: String?) async throws -> SearchPage
    /// Thumbnail (or the full file when there is none) for display; `thumbnail: false` for the original.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data
    /// Uploads a local file (`Attachment.localFile`) for a message in `conversation`; returns it with `uploadToken` set.
    func upload(_ attachment: Attachment, to conversation: ConversationID, thread: ThreadID?) async throws -> Attachment
    /// Everyone who has joined `conversation`, for @-mentions.
    func members(of conversation: ConversationID) async throws -> [Person]
    /// "I'm typing" (there is no "stopped": receivers time it out). Throttling is the caller's.
    func sendTyping(conversation: ConversationID, thread: ThreadID?) async throws
    /// The conversations open on screen, as a full replacement set: typing is only pushed for these.
    func watch(_ conversations: Set<ConversationID>) async
    /// One batched lookup; answers arrive as `.presenceChanged` events.
    func fetchPresence(_ people: [String]) async throws
    /// Do Not Disturb for `duration` seconds; it ends away. Each status call returns my status as the server saved it.
    func setDoNotDisturb(for duration: TimeInterval) async throws -> OwnStatus
    /// Away, or (false) automatic, which also ends Do Not Disturb.
    func setAway(_ away: Bool) async throws -> OwnStatus
    /// Sets my custom status, or clears it (nil).
    func setCustomStatus(_ status: CustomStatus?) async throws -> OwnStatus
    /// People to start a conversation with, matching `query` by name or email; never me.
    func searchPeople(_ query: String) async throws -> [Person]
    /// The DM with these people (one: 1:1, several: a group DM), found or else created.
    func directMessage(with people: [PersonID]) async throws -> Conversation
    /// Spaces in the directory matching `query`.
    func browseSpaces(_ query: String) async throws -> [SpaceListing]
    /// Joins a space and returns it as a conversation.
    func join(_ space: SpaceListing) async throws -> Conversation
    /// The media, files or links shared in a conversation, newest first, without its history;
    /// `after` is the last item of the previous page.
    func shared(_ category: SharedCategory, in conversation: ConversationID, after: SharedContent.Item?) async throws -> SharedPage
    /// The organisation's custom emoji that can be sent (enabled ones), every page.
    func customEmojis() async throws -> [CustomEmoji]
    /// The commands `conversation` offers whose name contains `query` (typed after the "/"; empty: the first page of all):
    /// its apps' and Google Chat's "Send a Meet link"; in an app's DM (`toApp`), that app's only.
    func slashCommands(in conversation: ConversationID, matching query: String, toApp: Bool) async throws -> [SlashCommand]
    /// Stars a message for me, or unstars it.
    func setStarred(_ starred: Bool, on id: MessageID) async throws
    /// Pins a message to its conversation's board, or takes it off; the board is shared by every member.
    func setPinned(_ pinned: Bool, on id: MessageID) async throws
    /// The messages on a conversation's board, as Google Chat's Board panel lists them.
    func pinnedMessages(in conversation: ConversationID) async throws -> [Message]
    /// The account's do not disturb schedules, with times in `timeZone`; saving replaces the whole set.
    func dndSchedules(timeZone: String) async throws -> DndSchedules
    func setDndSchedules(_ schedules: DndSchedules) async throws
    /// Sends a card button's action and the card's inputs back to its app; returns the message as the app updated it.
    func clickCard(_ id: MessageID, card: String?, action: Data, inputs: [Card.Input]) async throws -> Message?
    /// One of a dialog's requests (`DialogStep`): `action` is the pressed button's (nil when a slash command opens it or
    /// on close), `inputs` the dialog's (or, on open, the card's).
    func dialog(_ step: DialogStep, _ context: DialogContext, action: Data?, inputs: [Card.Input]) async throws -> DialogAnswer
    /// One page of a shortcut's messages, newest first; `cursor` is the previous page's.
    func shortcut(_ shortcut: Shortcut, cursor: String?) async throws -> SearchPage
    /// The threads Home lists, newest first, as the last `conversations()` brought them.
    func homeThreads() async -> [HomeThread]
    /// Every server draft.
    func drafts() async throws -> [ServerDraft]
    /// Creates the draft when its `id` is empty, else replaces its text and formatting; returns it as saved (id, update time).
    func saveDraft(_ draft: ServerDraft) async throws -> ServerDraft
    func deleteDraft(_ draft: ServerDraft) async throws
    /// Every scheduled message; `saveDraft` schedules one (a draft with a `schedule` and no id) and `deleteDraft` cancels it.
    func scheduled() async throws -> [ServerDraft]
    func reschedule(_ message: ServerDraft, to date: Date) async throws -> ServerDraft
}


enum AttachmentError: Error, LocalizedError, Equatable {
    case notAFile(String), empty(String), tooLarge(String)
    var errorDescription: String? {
        switch self {
        case .notAFile(let name): "“\(name)” isn’t a file that can be attached."
        case .empty(let name): "“\(name)” is empty."
        case .tooLarge(let name): "“\(name)” is larger than Google Chat’s 200 MB limit."
        }
    }
}
extension Attachment {
    /// Google Chat refuses larger uploads.
    static let maxUploadBytes = 200_000_000
    /// Not sent yet: a file on this Mac, shown from disk until the server's copy replaces it.
    var isLocalFile: Bool { url?.isFileURL == true }
    /// A file picked, pasted or dropped into the composer. Images keep their pixel size so the echo reserves its space.
    static func localFile(at url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard url.isFileURL, values?.isRegularFile == true, let size = values?.fileSize else { throw AttachmentError.notAFile(name) }
        guard size > 0 else { throw AttachmentError.empty(name) }
        guard size <= maxUploadBytes else { throw AttachmentError.tooLarge(name) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        var file = Attachment(name: name, contentType: type.preferredMIMEType ?? "application/octet-stream",
                              kind: type.conforms(to: .image) ? .image : .file, url: url)
        if file.kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            file.width = properties[kCGImagePropertyPixelWidth] as? Int
            file.height = properties[kCGImagePropertyPixelHeight] as? Int
            file.thumbnailURL = url
        }
        return file
    }
}

extension Message {
    /// How many emoji the message is when it is only one to three of them (custom ones too) and nothing else: drawn
    /// large and without a bubble, as Telegram and WhatsApp show them. Nil for any other message.
    var jumboEmoji: Int? {
        guard attachments.isEmpty, quote == nil,
              formatting.allSatisfy({ if case .customEmoji = $0.style { $0.length == 1 } else { false } }) else { return nil }
        let custom = Set(formatting.map(\.start))
        var count = 0, offset = 0   // UTF-16 offsets, as the formatting ranges count
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
    var isEmojiGlyph: Bool {
        guard let first = unicodeScalars.first?.properties else { return false }
        return first.isEmojiPresentation || (first.isEmoji && unicodeScalars.count > 1)
    }
}

extension ChatBackend {
    func searchMessages(_ query: String, cursor: String?) async throws -> SearchPage {
        try await searchMessages(query, filters: SearchFilters(), cursor: cursor)
    }
}
