import AppKit
import ParleyDomain

/// Label text, shared by the layout (measuring) and the row view (drawing with `TextLabel`).
extension RowLayout {
    static func dateText(_ message: Message, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(
            message.createdAt.formatted(date: .abbreviated, time: .omitted), .systemFont(ofSize: 11, weight: .medium),
            color, oneLine: true)
    }
    static func nameText(_ name: String, color: NSColor = .labelColor) -> NSAttributedString {
        styled(name, .systemFont(ofSize: 13 * TextSize.scale, weight: .semibold), color, oneLine: true)
    }
    static func viaText(_ app: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(app, .systemFont(ofSize: 10, weight: .medium), color, oneLine: true)
    }
    static func quoteSenderText(_ quote: QuotedMessage, color: NSColor = .labelColor) -> NSAttributedString {
        styled(
            quote.forwardedFrom.map { "↪ \(quote.sender) · from \($0)" } ?? quote.sender,
            .systemFont(ofSize: 12 * TextSize.scale, weight: .semibold), color, oneLine: true)
    }
    /// The quoted text, its custom emoji drawn as pictures (as the pills draw theirs).
    static func quoteBodyText(_ quote: QuotedMessage, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let text = styled(quote.text, .systemFont(ofSize: 13 * TextSize.scale), color)
        guard let emoji = quote.emoji, !emoji.isEmpty else { return text }
        let body = NSMutableAttributedString(attributedString: text)
        for range in emoji.sorted(by: { $0.start > $1.start }) where range.start + range.length <= body.length {
            guard case .customEmoji(let custom) = range.style else { continue }
            let at = NSRange(location: range.start, length: range.length)
            body.replaceCharacters(
                in: at,
                with: MessageTextStyle.customEmoji(
                    custom, attributes: body.attributes(at: at.location, effectiveRange: nil)))
        }
        return body
    }
    static func timeText(_ message: Message, color: NSColor = .secondaryLabelColor, timeOnly: Bool = false)
        -> NSAttributedString
    {
        let time = message.delivery == .pending ? "Sending…" : shortTime(message.createdAt)
        let text = styled(
            timeOnly ? time : (message.starred ? "★ " : "") + (message.edited ? "edited " : "") + time,
            .systemFont(ofSize: 11), color, oneLine: true)
        guard message.pinned, !timeOnly else { return text }
        // A pin before the time, as Google Chat marks a message on the board.
        let pin = NSTextAttachment()
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [color])))
        let marked = NSMutableAttributedString(attachment: pin)
        marked.append(styled(" ", .systemFont(ofSize: 11), color, oneLine: true))
        marked.append(text)
        marked.addAttribute(
            .paragraphStyle, value: text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as Any,
            range: NSRange(location: 0, length: marked.length))
        return marked
    }
    /// Formatted once per date: every layout and every row view needs its message's time.
    /// ponytail: a time zone or 12/24-hour change shows in newly formatted times only; key by both if it matters.
    private static func shortTime(_ date: Date) -> String {
        let key = NSNumber(value: date.timeIntervalSinceReferenceDate)
        if let cached = times.object(forKey: key) { return cached as String }
        let time = date.formatted(date: .omitted, time: .shortened)
        times.setObject(time as NSString, forKey: key)
        return time
    }
    nonisolated(unsafe) private static let times = NSCache<NSNumber, NSString>()  // NSCache is thread-safe
    static func pillText(_ reaction: Reaction, color: NSColor = .labelColor) -> NSAttributedString {
        let text = styled(
            "\(reaction.custom == nil ? reaction.emoji : "\u{FFFD}") \(reaction.people.count)", .systemFont(ofSize: 12),
            color, oneLine: true)
        guard let custom = reaction.custom else { return text }
        let pill = NSMutableAttributedString(attributedString: text)
        pill.replaceCharacters(
            in: NSRange(location: 0, length: 1),
            with: MessageTextStyle.customEmoji(custom, attributes: text.attributes(at: 0, effectiveRange: nil)))
        return pill
    }
    /// "2 replies", with " · 1 draft" when the thread's reply box holds a draft, as Google Chat shows it.
    static func repliesText(_ count: Int, draft: Bool = false, color: NSColor = .controlAccentColor)
        -> NSAttributedString
    {
        let parts = [count == 0 ? nil : count == 1 ? "1 reply" : "\(count) replies", draft ? "1 draft" : nil].compactMap
        { $0 }
        return styled(parts.joined(separator: " · "), .systemFont(ofSize: 12, weight: .medium), color, oneLine: true)
    }
    /// Google Chat's words for the toggle: "View original (Spanish)" over a translation, "Show translation" over the original.
    static func translationLabel(_ translation: ParleyDomain.Translation, showingOriginal: Bool) -> String {
        if showingOriginal { return "Show translation" }
        guard let language = Locale.current.localizedString(forLanguageCode: translation.from),
            language != translation.from
        else { return "View original" }
        return "View original (\(language))"
    }
    /// The toggle in small type after a translate icon, as Google Chat draws it under the bubble.
    static func translationText(
        _ translation: ParleyDomain.Translation, showingOriginal: Bool, color: NSColor = .controlAccentColor
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let text = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Translated")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(hierarchicalColor: color)))
        {
            let icon = NSTextAttachment()
            icon.image = image
            icon.bounds = CGRect(x: 0, y: font.descender + 1, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: icon))
            text.append(NSAttributedString(string: " "))
        }
        text.append(styled(translationLabel(translation, showingOriginal: showingOriginal), font, color, oneLine: true))
        return text
    }
    static func thinkingText(color: NSColor = .controlAccentColor) -> NSAttributedString {
        styled("Show thinking ›", .systemFont(ofSize: 12, weight: .medium), color, oneLine: true)
    }
    /// Up to three of the sources' kinds as icons, then "N Sources", as Google Chat heads the list.
    static func sourcesText(_ sources: [Source], color: NSColor = .controlAccentColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = NSMutableAttributedString()
        var kinds: [Source.Kind] = []
        for source in sources where !kinds.contains(source.kind) && kinds.count < 3 { kinds.append(source.kind) }
        for kind in kinds {
            let image = NSImage(systemSymbolName: symbol(kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color])))
            let icon = NSTextAttachment()
            icon.image = image
            text.append(NSAttributedString(attachment: icon))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: sources.count == 1 ? "1 Source" : "\(sources.count) Sources"))
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }
    static func symbol(_ kind: Source.Kind) -> String {
        switch kind {
        case .gmail: "envelope.fill"
        case .calendar: "calendar"
        case .docs: "doc.text.fill"
        case .sheets: "tablecells.fill"
        case .slides: "rectangle.on.rectangle.angled.fill"
        case .drive: "folder.fill"
        case .youtube: "play.rectangle.fill"
        case .chat: "bubble.left.fill"
        case .tasks: "checkmark.circle.fill"
        case .web: "globe"
        }
    }
    static func retryText(color: NSColor = .systemRed) -> NSAttributedString {
        styled("Couldn’t send · Retry", .systemFont(ofSize: 11), color, oneLine: true)
    }
    /// A 1:1 DM has one reader: "Seen". Group DMs name them by first name.
    static func seenText(_ names: [String], kind: ConversationKind, color: NSColor = .secondaryLabelColor)
        -> NSAttributedString
    {
        let first = names.map { String($0.split(separator: " ").first ?? Substring($0)) }
        return styled(
            kind == .direct ? "Seen" : "Seen by " + first.joined(separator: ", "), .systemFont(ofSize: 11), color)
    }
    static func serviceText(_ text: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(text, .systemFont(ofSize: 11, weight: .medium), color, alignment: .center)
    }
    static func styled(
        _ string: String, _ font: NSFont, _ color: NSColor = .labelColor, oneLine: Bool = false,
        alignment: NSTextAlignment = .natural
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = oneLine ? .byTruncatingTail : .byWordWrapping
        return NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    /// Options `TextLabel` draws with; measuring with the same ones keeps both in agreement.
    static let drawing: NSString.DrawingOptions = [
        .usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine,
    ]
    /// A label's size wrapped at `width`, at most `lines` lines (0: no limit).
    static func measure(_ text: NSAttributedString, width: CGFloat, lines: Int = 0) -> CGSize {
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: drawing)
        var height = ceil(rect.height)
        if lines > 0, text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            height = min(height, ceil((font.ascender - font.descender + font.leading) * CGFloat(lines)))
        }
        return CGSize(width: min(width, ceil(rect.width)), height: height)
    }
}
