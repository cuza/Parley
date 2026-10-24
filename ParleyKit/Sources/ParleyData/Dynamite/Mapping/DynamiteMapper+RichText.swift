import Foundation
import ParleyDomain

extension DynamiteMapper {
    /// Visible text and its styles. HIDDEN ranges (the literal `*`, `_`, `~`, `` ` `` markers) are cut out
    /// and every other range is shifted to match. Offsets are UTF-16 units; ranges past the end are skipped, as Google Chat does.
    static func richText(_ text: String, _ annotations: [Dynamite_Annotation], hiding extra: NSRange? = nil) -> (
        text: String, formatting: [TextStyleRange]
    ) {
        let count = text.utf16.count
        var hidden = IndexSet(integersIn: Range(extra ?? NSRange()) ?? 0..<0)
        var styles: [(TextStyleRange.Style, NSRange)] = []
        for annotation in annotations {
            let range = NSRange(location: Int(annotation.startIndex), length: Int(annotation.length))
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= count else { continue }
            if case .formatMetadata(let format)? = annotation.metadata, format.formatType == .hidden {
                hidden.insert(integersIn: range.location..<NSMaxRange(range))
            } else if let style = style(annotation) {
                styles.append((style, range))
            }
        }
        func shift(_ offset: Int) -> Int { offset - hidden.count(in: 0..<offset) }
        let formatting = styles.compactMap { style, range -> TextStyleRange? in
            let start = shift(range.location)
            let end = shift(NSMaxRange(range))
            return end > start ? TextStyleRange(style: style, start: start, length: end - start) : nil
        }
        let visible = NSMutableString(string: text)
        for cut in hidden.rangeView.reversed() { visible.deleteCharacters(in: NSRange(cut)) }
        return (visible as String, numberingLists(formatting))
    }
    /// The style an annotation over the text draws; nil for one that draws none (and for HIDDEN, which cuts its text).
    private static func style(_ annotation: Dynamite_Annotation) -> TextStyleRange.Style? {
        switch annotation.metadata {
        case .formatMetadata(let format):
            return style(format)
        case .userMentionMetadata(let mention):
            let id =
                mention.type == .mentionAll ? TextStyleRange.everyone : mention.id.id.nilIfEmpty.map { PersonID($0) }
            if mention.type != .mentionAll, mention.id.type == .bot, let id { return .appMention(userID: id) }
            return .mention(userID: id)
        case .customEmojiMetadata(let metadata):  // one U+FFFD in the text
            return customEmoji(metadata.customEmoji).map { .customEmoji($0) }
        case .urlMetadata(let link):
            return URL(string: link.url.url).map { .link($0) }
        case .driveMetadata:  // a Drive file's chip in the text (its title): a link to the file, beside its card
            guard let url = URL(string: annotation.interactionData.url.url), url.scheme == "https" else { return nil }
            return .link(url)
        case .groupMetadata(let chip):  // a space or DM chip: drawn as Google Chat draws it, opening in place
            return DynamiteID.conversation(chip.groupID).map {
                .chip($0, emoji: chip.avatarInfo.emoji.unicode.nilIfEmpty)
            }
        default:
            return nil
        }
    }
    private static func style(_ format: Dynamite_FormatMetadata) -> TextStyleRange.Style? {
        switch format.formatType {
        case .bold: .bold
        case .italic: .italic
        case .strike: .strike
        case .underline: .underline
        case .monospace: .code
        case .monospaceBlock: .codeBlock
        case .bulletedListItem:  // nested or numbered ones say so; a plain bullet stays the composer's own style
            listStyle(level: Int(min(max(format.list.nestingLevel, 0), 4)), numbered: format.list.listType == 2)
        case .heading: .heading
        case .quoteBlock: .quote
        case .fontColor: .color(format.fontColor)
        default: nil
        }
    }
    private static func listStyle(level: Int, numbered: Bool) -> TextStyleRange.Style {
        level == 0 && !numbered ? .listItem : .list(level: level, number: numbered ? 0 : nil)
    }
    /// Numbered items count up within their list and level; a deeper level starts again under each item.
    private static func numberingLists(_ formatting: [TextStyleRange]) -> [TextStyleRange] {
        var formatting = formatting
        var counts: [Int] = []
        var end = -1
        for index in formatting.indices.sorted(by: { formatting[$0].start < formatting[$1].start }) {
            let item = formatting[index]
            guard case .list(let level, let number) = item.style else {
                if case .listItem = item.style {
                    counts = [0]
                    end = item.start + item.length
                }
                continue
            }
            if item.start > end + 1 { counts = [] }  // a new list
            counts = Array(counts.prefix(level + 1)) + Array(repeating: 0, count: max(0, level + 1 - counts.count))
            if number != nil {
                counts[level] += 1
                formatting[index].style = .list(level: level, number: counts[level])
            } else {
                counts[level] = 0
            }
            end = item.start + item.length
        }
        return formatting
    }

    /// FORMAT_DATA annotations for marker-free text, as Google Chat's composer sends them:
    /// one BULLETED_LIST_ITEM per line, plus one BULLETED_LIST over each run of adjacent items. Mentions become USER_MENTION
    /// annotations, custom emoji CUSTOM_EMOJI ones and links URL ones; mentions without a user are skipped.
    /// `outsiders`: mentioned people who aren't members, sent as INVITE or REFERENCE instead of MENTION.
    static func annotations(_ formatting: [TextStyleRange], outsiders: [PersonID: MessageDraft.Outsider] = [:])
        -> [Dynamite_Annotation]
    {
        var annotations: [Dynamite_Annotation] = []
        var lists: [(start: Int, end: Int)] = []
        var chips = false
        var files = false
        for range in formatting where range.length > 0 {
            if let made = entity(range, outsiders: outsiders) {
                annotations.append(made)
                if case .chip = range.style { chips = true }
                if case .drive = range.style { files = true }
                continue
            }
            guard let type = formatType(range.style) else { continue }
            if type == .bulletedListItem {
                if let last = lists.last, last.end == range.start {
                    lists[lists.count - 1].end = range.start + range.length
                } else {
                    lists.append((range.start, range.start + range.length))
                }
            }
            var made = format(type, range.start, range.length)
            if case .list(let level, let number) = range.style {  // kept as it came, so an edit doesn't flatten it
                made.formatMetadata.list.nestingLevel = Int32(level)
                made.formatMetadata.list.listType = number == nil ? 1 : 2
            }
            annotations.append(made)
        }
        // A message with chips says so, as Google Chat records it: Drive smart chips (4), group smart chips (6). Clients
        // without them show the chips as they can, and web Chat draws a space chip only with it.
        let needed = (files ? [Int32(4)] : []) + (chips ? [Int32(6)] : [])
        let features = Dynamite_Annotation.with { annotation in
            annotation.type = .requiredMessageFeaturesMetadata
            annotation.chipRenderType = .render
            annotation.requiredMessageFeaturesMetadata.requiredFeatures = needed
        }
        return annotations + lists.map { format(.bulletedList, $0.start, $0.end - $0.start) }
            + (needed.isEmpty ? [] : [features])
    }
    /// The annotation a mention, custom emoji, link, chip, Drive file or colour is sent as; nil for other styles, and for
    /// a chip whose conversation id is malformed.
    private static func entity(_ range: TextStyleRange, outsiders: [PersonID: MessageDraft.Outsider])
        -> Dynamite_Annotation?
    {
        switch range.style {
        case .mention(let id?):
            var annotation = mention(id.rawValue, range.start, range.length)
            switch outsiders[id] {
            case .invite: annotation.userMentionMetadata.type = .invite
            case .reference: annotation.userMentionMetadata.type = .reference
            case nil: break
            }
            return annotation
        case .appMention(let id): return mention(id.rawValue, range.start, range.length, app: true)
        case .customEmoji(let emoji): return customEmoji(emoji, range.start, range.length)
        case .link(let url): return link(url, range.start, range.length)
        case .chip(let room, let emoji, let link):
            return chip(room, emoji: emoji, link: link, range.start, range.length)
        case .drive(let file): return drive(file, range.start, range.length)
        case .color(let argb):
            var colour = format(.fontColor, range.start, range.length)
            colour.formatMetadata.fontColor = argb
            return colour
        default: return nil
        }
    }
    /// The FORMAT_DATA kind a style is sent as; nil for styles sent another way or not at all.
    private static func formatType(_ style: TextStyleRange.Style) -> Dynamite_FormatMetadata.FormatType? {
        switch style {
        case .bold: .bold
        case .italic: .italic
        case .strike: .strike
        case .underline: .underline
        case .code: .monospace
        case .codeBlock: .monospaceBlock
        case .quote: .quoteBlock
        case .listItem, .list: .bulletedListItem
        case .heading, .mention, .appMention, .link, .customEmoji, .color, .chip, .drive, .small, .nowrap,
            .slashCommand:
            nil  // a command: `slashCommand(_:)`, on send only
        }
    }
    private static func format(_ type: Dynamite_FormatMetadata.FormatType, _ start: Int, _ length: Int)
        -> Dynamite_Annotation
    {
        .with {
            $0.type = .formatData
            $0.startIndex = Int32(start)
            $0.length = Int32(length)
            $0.formatMetadata.formatType = type
        }
    }
    /// A space or DM chip as Google Chat's composer sends one made from a pasted link: drawn inline (no chip card), opening
    /// the link, with the space's emoji and, for a message's link, that message.
    static func chip(_ room: ConversationID, emoji: String?, link: URL?, _ start: Int, _ length: Int)
        -> Dynamite_Annotation?
    {
        guard let group = try? DynamiteID.group(room) else { return nil }
        return .with { annotation in
            annotation.type = .group
            annotation.startIndex = Int32(start)
            annotation.length = Int32(length)
            annotation.chipRenderType = .doNotRender
            annotation.inlineRenderFormat = 1
            annotation.interactionData.url.url = (link ?? ChatLink.url(room)).absoluteString
            annotation.groupMetadata.groupID = group
            if let emoji { annotation.groupMetadata.avatarInfo.emoji.unicode = emoji }
            if let chat = link.flatMap(ChatLink.init), let topic = chat.topic,
                let id = try? DynamiteID.protoMessageID(
                    DynamiteID.message(room, topic: topic, message: chat.message ?? topic))
            {
                annotation.groupMetadata.messageID = id
            }
        }
    }

    /// A Drive file's chip as Google Chat's web sends one picked from the @ list: over its title, drawn if possible, inline.
    static func drive(_ file: DriveFile, _ start: Int, _ length: Int) -> Dynamite_Annotation {
        .with { annotation in
            annotation.type = .driveFile
            annotation.startIndex = Int32(start)
            annotation.length = Int32(length)
            annotation.chipRenderType = .renderIfPossible
            annotation.inlineRenderFormat = 1
            annotation.driveMetadata.id = file.id
            annotation.driveMetadata.title = file.title
            annotation.driveMetadata.mimeType = file.mimeType
            annotation.driveMetadata.field9 = false
            annotation.driveMetadata.field12 = .init()
        }
    }
    /// A link with its own text, as Google Chat's composer sends one: a RICH_TEXT URL annotation over the text.
    static func link(_ url: URL, _ start: Int, _ length: Int) -> Dynamite_Annotation {
        .with { annotation in
            annotation.type = .url
            annotation.startIndex = Int32(start)
            annotation.length = Int32(length)
            annotation.chipRenderType = .render
            annotation.urlMetadata = .with {
                $0.url.url = url.absoluteString
                $0.urlSource = .richText
                $0.shouldNotRender = false
            }
        }
    }
    /// A mention as Google Chat's composer builds it: the user id with type HUMAN, mention
    /// type MENTION, and the same id again as invitee info; @all is MENTION_ALL with no user. The range covers the `@Name` text.
    /// `app`: an app's mention, sent as a bot's (UserId type BOT), as Google Chat sends one picked from the Apps section.
    static func mention(_ userID: String, _ start: Int, _ length: Int, app: Bool = false) -> Dynamite_Annotation {
        let user = Dynamite_UserId.with {
            $0.id = userID
            $0.type = app ? .bot : .human
        }
        return .with { annotation in
            annotation.type = .userMention
            annotation.startIndex = Int32(start)
            annotation.length = Int32(length)
            annotation.userMentionMetadata =
                userID == TextStyleRange.everyone.rawValue
                ? .with { $0.type = .mentionAll }
                : .with {
                    $0.id = user
                    $0.type = .mention
                    $0.inviteeInfo.userID = user
                }
        }
    }

    /// A custom emoji over its U+FFFD, carrying the emoji exactly as the server sent it.
    static func customEmoji(_ emoji: CustomEmoji, _ start: Int, _ length: Int) -> Dynamite_Annotation {
        .with { annotation in
            annotation.type = .customEmoji
            annotation.startIndex = Int32(start)
            annotation.length = Int32(length)
            annotation.customEmojiMetadata.customEmoji = DynamiteMapper.emoji(emoji.text, custom: emoji).customEmoji
        }
    }
}
