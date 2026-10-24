import Foundation

/// A style over part of `Message.text`, in UTF-16 units (`NSRange` offsets).
public struct TextStyleRange: Hashable, Codable, Sendable {
    public enum Style: Hashable, Codable, Sendable {
        case bold, italic, strike, underline, code, codeBlock, listItem, heading, quote
        case small  // a card's small print (a bottom label): smaller type
        case nowrap  // its paragraph stays on one line, cut with "…" (a card row that doesn't wrap)
        case list(level: Int, number: Int?)  // a nested (level 1…4) or numbered list item; a plain one is `listItem`
        case mention(userID: PersonID?)  // the mentioned user; nil in launch caches written before it was kept
        case link(URL)
        case customEmoji(CustomEmoji)  // over the one U+FFFD that stands for it
        case color(UInt32)  // text colour, ARGB, as Google Chat stores it
        // A space or DM chip over its name: the space's emoji when known, and the link it was made from (a message's, maybe).
        case chip(ConversationID, emoji: String? = nil, link: URL? = nil)
        case slashCommand(SlashCommand)  // over a picked command's name at the start: the message invokes it
        case drive(DriveFile)  // a Drive file's chip over its title, picked from the @ list
        case appMention(userID: PersonID)  // an app's mention ("@Poll"), sent as a bot's
    }
    public var style: Style
    public var start: Int
    public var length: Int
    public init(style: Style, start: Int, length: Int) {
        self.style = style
        self.start = start
        self.length = length
    }
    /// The user id an @all mention carries.
    public static let everyone: PersonID = "@all"
    /// `plain(_:_:)`'s text, with where each custom emoji's ":shortcode:" ended up, for text that draws them as pictures.
    public static func plainWithEmoji(_ text: String, _ formatting: [TextStyleRange]) -> (
        text: String, emoji: [TextStyleRange]
    ) {
        let plain = NSMutableString(string: text)
        var emoji: [TextStyleRange] = []
        var shift = 0
        for range in formatting.sorted(by: { $0.start < $1.start })
        where range.start >= 0 && range.start + range.length <= (text as NSString).length {
            guard case .customEmoji(let custom) = range.style else { continue }
            let at = NSRange(location: range.start + shift, length: range.length)
            let code = custom.text as NSString
            plain.replaceCharacters(in: at, with: code as String)
            emoji.append(TextStyleRange(style: range.style, start: at.location, length: code.length))
            shift += code.length - range.length
        }
        return (plain as String, emoji)
    }
    /// `text` with each custom emoji written as ":shortcode:", for places that show plain text (quotes, notifications).
    public static func plain(_ text: String, _ formatting: [TextStyleRange]) -> String {
        let plain = NSMutableString(string: text)
        for range in formatting.sorted(by: { $0.start > $1.start })
        where range.start >= 0 && range.start + range.length <= plain.length {
            if case .customEmoji(let emoji) = range.style {
                plain.replaceCharacters(in: NSRange(location: range.start, length: range.length), with: emoji.text)
            }
        }
        return plain as String
    }
}
/// The text colours Google Chat's composer offers, with the ARGB values it sends; light and dark alike.
public enum TextColor: CaseIterable, Sendable {
    case red, blue, green, amber, grey
    public var argb: UInt32 {
        switch self {
        case .red: 0xFFF4_4336
        case .blue: 0xFF21_96F3
        case .green: 0xFF4C_AF50
        case .amber: 0xFFFF_C107
        case .grey: 0xFF9E_9E9E
        }
    }
    public var name: String { "\(self)".capitalized }
}
