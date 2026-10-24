import AppKit
import ParleyDomain

/// Message text styling and TextKit 1 measurement, shared by `NativeMessageText` and the timeline's `RowLayout`
/// so measured and drawn text agree. Nonisolated: row layouts may be computed off the main actor.
enum MessageTextStyle {
    /// On a mention of one person (not @all): their user id, for the person card a click on it shows.
    static let mentionKey = NSAttributedString.Key("Parley.message.mention")
    private static let customEmojiKey = NSAttributedString.Key("Parley.message.customEmoji")
    /// On a drawn custom emoji: the `CustomEmoji`, for the hover card.
    static let emojiKey = NSAttributedString.Key("Parley.message.emoji")
    /// On a space or DM chip: the conversation's link, opened on click (a chip is a pill, not an underlined link).
    static let chipKey = NSAttributedString.Key("Parley.message.chip")
    static func key(
        _ text: String, _ formatting: [TextStyleRange], _ quote: QuotedMessage?, _ own: Bool, jumbo: Int? = nil
    ) -> String {
        jumbo.map { "\($0)\u{1}" + key(text, formatting, quote, own) }
            ?? (formatting.isEmpty && quote == nil
                ? "\(own)\u{0}\(text)" : "\(own)\u{0}\(text)\u{0}\(formatting)\u{0}\(String(describing: quote))")
    }
    /// Large emoji (`Message.jumboEmoji`): one at 56 pt, two at 48, three at 40, as Telegram steps them down.
    static func jumboFont(_ count: Int) -> NSFont { .systemFont(ofSize: [56, 48, 40][min(max(count, 1), 3) - 1]) }
    /// The used size of `styled` wrapped at `width` (TextKit 1 with no line-fragment padding, like the message text view),
    /// and how far its last line reaches. A last line inside a block (code, quote) reports the full width.
    /// `brokeWord`: a line ends inside a word (one too long for the line), so the text may wrap differently at any narrower width.
    static func measure(_ styled: NSAttributedString, width: CGFloat, lines: Int = 0) -> (
        size: CGSize, lastLine: CGFloat, brokeWord: Bool
    ) {
        RowLayout.tally?.texts += 1
        let stack = TextStack.current
        let manager = stack.manager
        let container = stack.container
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        container.maximumNumberOfLines = lines
        stack.storage.setAttributedString(styled)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        var lastLine: CGFloat = 0  // 0 after a trailing newline: the last line is empty
        if styled.length > 0, manager.extraLineFragmentRect.isEmpty {
            let style =
                styled.attribute(.paragraphStyle, at: styled.length - 1, effectiveRange: nil) as? NSParagraphStyle
            lastLine =
                style?.textBlocks.isEmpty == false
                ? width
                : manager.lineFragmentUsedRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil).maxX
        }
        var brokeWord = false
        let text = styled.string as NSString
        func breaks(_ unit: unichar) -> Bool {
            UnicodeScalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, _, _, glyphs, stop in
            let end = NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            if end > 0, end < text.length, !breaks(text.character(at: end - 1)), !breaks(text.character(at: end)) {
                brokeWord = true
                stop.pointee = true
            }
        }
        return (CGSize(width: ceil(used.width), height: ceil(used.height)), ceil(lastLine), brokeWord)
    }
    /// One TextKit stack per thread, reused by every `measure` on it instead of one built and freed per measure.
    private final class TextStack {
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer()
        init() {
            container.lineFragmentPadding = 0
            manager.backgroundLayoutEnabled = false
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
        }
        static var current: TextStack {
            let key = "Parley.MessageTextStyle.stack"
            if let stack = Thread.current.threadDictionary[key] as? TextStack { return stack }
            let stack = TextStack()
            Thread.current.threadDictionary[key] = stack
            return stack
        }
    }
    // Phase 2 (PARLEY-193): one switch over every style, to be split into a function per kind of style.
    /// Message text with its `TextStyleRange`s applied (ranges past the end are skipped), list bullets, and the quoted message on top.
    /// Blocks use TextKit 1 `NSTextBlock`s (borders, padding, backgrounds), which both the view and `measure` lay out.
    /// `scale` is View ▸ Bigger and Smaller's (`TextSize`); large emoji keep their size.
    static func styled(  // swiftlint:disable:this cyclomatic_complexity
        _ text: String, _ formatting: [TextStyleRange] = [], _ quote: QuotedMessage? = nil, own: Bool,
        jumbo: Int? = nil,
        scale: CGFloat = TextSize.scale
    ) -> NSAttributedString {
        let key = "\(scale)\u{2}" + key(text, formatting, quote, own, jumbo: jumbo)
        let font = jumbo.map(jumboFont) ?? .systemFont(ofSize: 14 * scale)
        let mono = NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
        if let cached = styledCache.object(forKey: key as NSString) { return cached }
        let ink = BubblePalette.ownInk
        let color: NSColor = own ? ink : .labelColor
        let secondary: NSColor = own ? BubblePalette.ownAccent.withAlphaComponent(0.8) : .secondaryLabelColor
        let tint: NSColor = own ? ink.withAlphaComponent(0.2) : .labelColor.withAlphaComponent(0.08)
        let styled = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let all = NSRange(location: 0, length: styled.length)
        let string = styled.string as NSString
        for match in links.matches(in: text, range: all) {
            if let url = match.url { styled.addAttribute(.link, value: url, range: match.range) }
        }
        let ranges = formatting.filter { $0.start >= 0 && $0.length > 0 && $0.start + $0.length <= all.length }
        var bullets = IndexSet()
        var inserts: [(at: Int, text: String, like: Int)] = []  // text added around a chip, styled as the character `like`
        for range in ranges {  // fonts and blocks first; bold and italic then add traits to whichever font is there
            let span = NSRange(location: range.start, length: range.length)
            let paragraph = string.paragraphRange(for: span)
            switch range.style {
            case .code: styled.addAttributes([.font: mono, .backgroundColor: tint], range: span)
            case .codeBlock:
                styled.addAttribute(.font, value: mono, range: span)
                styled.addAttributes([.paragraphStyle: indented(8, tail: 8), codeFillKey: tint], range: paragraph)
            case .heading:
                styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 17 * scale, weight: .semibold), range: span)
            case .small: styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 12 * scale), range: span)
            case .nowrap:
                let line = NSMutableParagraphStyle()
                line.lineBreakMode = .byTruncatingTail
                styled.addAttribute(.paragraphStyle, value: line, range: paragraph)
            case .strike: styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span)
            case .underline: styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span)
            case .link(let url): styled.addAttribute(.link, value: url, range: span)
            case .drive(let file):  // a chip just sent: the server's copy links it to the file's own page
                if let url = URL(string: "https://drive.google.com/open?id=\(file.id)") {
                    styled.addAttribute(.link, value: url, range: span)
                }
            case .quote:
                styled.addAttribute(.foregroundColor, value: secondary, range: span)
                styled.addAttributes([.paragraphStyle: indented(12), quoteBarKey: secondary], range: paragraph)
            case .listItem:
                let indent = NSMutableParagraphStyle()
                indent.headIndent = 12
                styled.addAttribute(.paragraphStyle, value: indent, range: paragraph)
                bullets.insert(paragraph.location)
            case .list(let level, let number):  // as web draws nested lists: deeper, then ◦ and ▪; numbers stay numbers
                let marker = number.map { "\($0). " } ?? ["• ", "◦ ", "▪ "][min(level, 2)]
                let indent = NSMutableParagraphStyle()
                indent.firstLineHeadIndent = CGFloat(level) * 16
                indent.headIndent =
                    indent.firstLineHeadIndent + (marker as NSString).size(withAttributes: [.font: font]).width
                styled.addAttribute(.paragraphStyle, value: indent, range: paragraph)
                inserts.append((paragraph.location, marker, paragraph.location))
            case .appMention:  // an app's mention: tinted as a person's
                if !own { styled.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span) }
            case .mention(let id):  // one person's mention carries their id, for the card a click shows
                if !own { styled.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span) }
                if let id, id != TextStyleRange.everyone {
                    styled.addAttributes([mentionKey: id.rawValue, .cursor: NSCursor.pointingHand], range: span)
                }
            case .customEmoji(let emoji): styled.addAttribute(customEmojiKey, value: emoji, range: span)
            case .color(let argb):
                styled.addAttribute(.foregroundColor, value: NSColor(rgb: argb & 0xFF_FFFF), range: span)  // as is, as web shows it
            case .chip(let room, let emoji, _):  // Google Chat's pill: the space's emoji and name on a tint, rounded where drawn
                styled.addAttributes(
                    [chipKey: ChatLink.url(room), .backgroundColor: tint, .cursor: NSCursor.pointingHand], range: span)
                inserts.append((NSMaxRange(span), "\u{2009}", span.location + span.length - 1))
                inserts.append((span.location, "\u{2009}" + (emoji.map { $0 + "\u{2009}" } ?? ""), span.location))
            case .bold, .italic: break
            case .slashCommand: break  // the command as typed, as Google Chat shows it
            }
        }
        addFontTraits(ranges, to: styled)
        drawCustomEmoji(in: styled)
        inserts += bullets.map { ($0, "• ", $0) }
        insert(inserts, into: styled)
        if let quote { styled.insert(quoteHeader(quote, scale: scale, color: secondary), at: 0) }
        styledCache.setObject(styled, forKey: key as NSString)
        return styled
    }
    /// Bold and italic, added to whichever font each range already has.
    private static func addFontTraits(_ ranges: [TextStyleRange], to styled: NSMutableAttributedString) {
        for range in ranges {
            guard let trait = fontTrait(range.style) else { continue }
            let span = NSRange(location: range.start, length: range.length)
            styled.enumerateAttribute(.font, in: span) { value, sub, _ in
                guard let current = value as? NSFont else { return }
                let descriptor = current.fontDescriptor.withSymbolicTraits(
                    current.fontDescriptor.symbolicTraits.union(trait))
                styled.addAttribute(
                    .font, value: NSFont(descriptor: descriptor, size: current.pointSize) ?? current, range: sub)
            }
        }
    }
    /// Each custom emoji's replacement character, swapped for its picture.
    private static func drawCustomEmoji(in styled: NSMutableAttributedString) {
        let all = NSRange(location: 0, length: styled.length)
        let string = styled.string as NSString
        var emoji: [(CustomEmoji, Int)] = []  // replaced from the end, after the styles, so earlier offsets stay valid
        styled.enumerateAttribute(customEmojiKey, in: all) { value, range, _ in
            guard let value = value as? CustomEmoji else { return }
            for index in range.location..<NSMaxRange(range) where string.character(at: index) == 0xFFFD {
                emoji.append((value, index))
            }
        }
        for (value, index) in emoji.reversed() {
            var attributes = styled.attributes(at: index, effectiveRange: nil)
            attributes[customEmojiKey] = nil
            styled.replaceCharacters(
                in: NSRange(location: index, length: 1), with: customEmoji(value, attributes: attributes))
        }
    }
    /// List markers and the space round a chip, each styled as the character `like`.
    private static func insert(_ inserts: [(at: Int, text: String, like: Int)], into styled: NSMutableAttributedString)
    {
        for insert in inserts.sorted(by: { $0.at > $1.at }) {  // from the end, so earlier offsets stay valid
            styled.insert(
                NSAttributedString(
                    string: insert.text, attributes: styled.attributes(at: insert.like, effectiveRange: nil)),
                at: insert.at)
        }
    }
    /// The quoted message's sender and text, set above the message with a quote's bar.
    private static func quoteHeader(_ quote: QuotedMessage, scale: CGFloat, color secondary: NSColor)
        -> NSAttributedString
    {
        let style = indented(12)
        let header = NSMutableAttributedString(
            string: quote.sender + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12 * scale, weight: .semibold), .foregroundColor: secondary,
                .paragraphStyle: style, quoteBarKey: secondary,
            ])
        let quoted = NSMutableAttributedString(
            string: quote.text + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13 * scale), .foregroundColor: secondary, .paragraphStyle: style,
                quoteBarKey: secondary,
            ])
        for range in (quote.emoji ?? []).sorted(by: { $0.start > $1.start })
        where range.start + range.length < quoted.length {  // as pictures
            guard case .customEmoji(let emoji) = range.style else { continue }
            let at = NSRange(location: range.start, length: range.length)
            quoted.replaceCharacters(
                in: at,
                with: customEmoji(emoji, attributes: quoted.attributes(at: at.location, effectiveRange: nil)))
        }
        header.append(quoted)
        return header
    }
    /// The font trait a style adds: bold for bold and mentions, italic for italic.
    private static func fontTrait(_ style: TextStyleRange.Style) -> NSFontDescriptor.SymbolicTraits? {
        switch style {
        case .bold, .mention: .bold
        case .italic: .italic
        default: nil
        }
    }

    /// A custom emoji at the size of the text around it: its image once `ImageCache` has it (a faint square until then,
    /// so loading never moves the layout), or ":shortcode:" when it was deleted or has no image.
    static func customEmoji(_ emoji: CustomEmoji, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard !emoji.deleted, let picture = emoji.image else {
            return NSAttributedString(string: emoji.text, attributes: attributes)
        }
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 14 * TextSize.scale)
        let placeholder = (attributes[.foregroundColor] as? NSColor ?? .labelColor).withAlphaComponent(0.15)
        let side = ceil(font.ascender - font.descender)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Drawn on the main thread by the text view or label; `MessageRowView` redraws once the picture arrives, and
            // while an animated one shows, so this picks its frame for the time.
            let drawn =
                Thread.isMainThread
                && MainActor.assumeIsolated { () -> Bool in
                    guard let loaded = ImageCache.cached(picture), loaded.size.width > 0, loaded.size.height > 0 else {
                        return false
                    }
                    let scale = min(rect.width / loaded.size.width, rect.height / loaded.size.height)
                    let size = NSSize(width: loaded.size.width * scale, height: loaded.size.height * scale)
                    loaded.drawFrame(
                        in: NSRect(
                            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                            height: size.height))
                    return true
                }
            if !drawn {
                placeholder.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
        image.cacheMode = .never  // the drawing handler decides each time: placeholder, then the picture
        image.accessibilityDescription = emoji.text
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        result.addAttribute(emojiKey, value: emoji, range: NSRange(location: 0, length: result.length))  // for its hover card
        return result
    }
    /// A paragraph block: a leading bar (quotes) or a tinted background (code).
    /// Every line of a quote or code block indented alike (TextKit's text blocks indented only the first line in a
    /// timeline row); `MessageLayoutManager` draws the quote's bar and the code's background over the block's lines.
    private static func indented(_ indent: CGFloat, tail: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tailIndent = -tail
        style.paragraphSpacing = 2
        return style
    }
    /// On a quote's lines: the colour of the bar drawn beside them.
    static let quoteBarKey = NSAttributedString.Key("Parley.message.quoteBar")
    /// On a code block's lines: the colour of the background drawn behind them.
    static let codeFillKey = NSAttributedString.Key("Parley.message.codeFill")
    // A constant pattern: the link detector is always made.
    // swiftlint:disable:next force_try
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private nonisolated(unsafe) static let styledCache = NSCache<NSString, NSAttributedString>()  // NSCache is thread-safe
}
