import AppKit
import ParleyDomain

/// Each composer style is a custom attribute and `visual` derives fonts, strikes and indents from them, so the
/// attributes alone define `formatting`. Shortcuts: ⌘B bold, ⌘I italic, ⌘U underline, ⇧⌘X strikethrough, ⇧⌘C code
/// (⌘E is "edit last message"), ⌥⇧⌘C code block, ⌘' quote, ⇧⌘8 bulleted list, ⇧⌘K link (⌘K is
/// Jump to Conversation). The formatting bar and the right-click Format menu send the `format…` actions.
extension ComposerTextView {
    static let styles: [TextStyleRange.Style] = [
        .bold, .italic, .underline, .strike, .code, .codeBlock, .quote, .listItem,
    ]
    /// Styles that cover whole lines.
    static let lineStyles: [TextStyleRange.Style] = [.codeBlock, .quote, .listItem]
    static func key(_ style: TextStyleRange.Style) -> NSAttributedString.Key { .init("Parley.composer.\(style)") }
    /// Text colour (an ARGB `UInt32`) and links (a `URL`) carry a value, so they have keys of their own.
    static let colorKey = NSAttributedString.Key("Parley.composer.textColor"),
        linkKey = NSAttributedString.Key("Parley.composer.link")
    @objc func formatBold(_ sender: Any?) { toggle(.bold) }
    @objc func formatItalic(_ sender: Any?) { toggle(.italic) }
    @objc func formatStrike(_ sender: Any?) { toggle(.strike) }
    @objc func formatCode(_ sender: Any?) { toggle(.code) }
    @objc func formatList(_ sender: Any?) { toggle(.listItem) }
    @objc func formatUnderline(_ sender: Any?) { toggle(.underline) }
    @objc func formatCodeBlock(_ sender: Any?) { toggle(.codeBlock) }
    @objc func formatQuote(_ sender: Any?) { toggle(.quote) }
    @objc func formatLink(_ sender: Any?) { askForLink?() }
    /// A colour menu item's tag is its `TextColor` index; -1 is the default colour.
    @objc func formatColor(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        color(TextColor.allCases.indices.contains(tag) ? TextColor.allCases[tag] : nil)
    }
    func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        func item(
            _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
        }
        item("Bold", #selector(formatBold), "b")
        item("Italic", #selector(formatItalic), "i")
        item("Underline", #selector(formatUnderline), "u")
        item("Strikethrough", #selector(formatStrike), "x", [.command, .shift])
        let colors = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        colors.submenu = NSMenu(title: "Text Color")
        for (index, color) in [(-1, nil)] + TextColor.allCases.enumerated().map({ ($0.offset, Optional($0.element)) }) {
            let swatch = NSMenuItem(title: color?.name ?? "Default", action: #selector(formatColor), keyEquivalent: "")
            swatch.tag = index
            swatch.target = self
            swatch.image = color.map { Self.swatch(NSColor(rgb: $0.argb & 0xFF_FFFF)) } ?? Self.swatch(.textColor)
            colors.submenu?.addItem(swatch)
        }
        menu.addItem(colors)
        menu.addItem(.separator())
        item("Bulleted List", #selector(formatList), "8", [.command, .shift])
        item("Quote", #selector(formatQuote), "'")
        item("Link…", #selector(formatLink), "k", [.command, .shift])
        menu.addItem(.separator())
        item("Code", #selector(formatCode), "c", [.command, .shift])
        item("Code Block", #selector(formatCodeBlock), "c", [.command, .shift, .option])
        menu.addItem(.separator())
        item("Clear Formatting", #selector(formatClear))
        return menu
    }
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
    /// Takes every style off the selection, as Telegram's Clear Formatting; mentions and custom emoji stay.
    @objc func formatClear(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        for key in Self.styles.map(Self.key) + [Self.colorKey, Self.linkKey] {
            storage.removeAttribute(key, range: range)
        }
        Self.restyle(storage, in: range)
        didChangeText()
    }
    /// The colour of the selection's first character, or of what is typed next; nil for the default colour.
    var currentColor: TextColor? {
        let range = selectedRange()
        let value =
            range.length > 0 && range.location < (textStorage?.length ?? 0)
            ? textStorage?.attribute(Self.colorKey, at: range.location, effectiveRange: nil)
            : typingAttributes[Self.colorKey]
        return (value as? NSNumber).flatMap { argb in TextColor.allCases.first { $0.argb == argb.uint32Value } }
    }
    /// Colours the selection, or what is typed next; nil is the default colour.
    func color(_ color: TextColor?) { apply(Self.colorKey, color.map { NSNumber(value: $0.argb) }) }
    /// Makes the selection a link; with nothing selected (or new `text`), types `text` (else the address) as the link.
    func link(_ url: URL, text: String?) {
        let range = selectedRange()
        if range.length > 0, text == nil || text == (string as NSString).substring(with: range) {
            apply(Self.linkKey, url)
            return
        }
        let shown = text?.isEmpty == false ? text! : url.absoluteString
        var attributes = typingAttributes
        attributes[Self.linkKey] = url
        guard shouldChangeText(in: range, replacementString: shown) else { return }
        textStorage?.replaceCharacters(
            in: range, with: NSAttributedString(string: shown, attributes: Self.visual(attributes)))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (shown as NSString).length, length: 0))
        typingAttributes = Self.visual(typingAttributes.filter { $0.key != Self.linkKey })  // typing on after it isn't the link
    }
    private func apply(_ key: NSAttributedString.Key, _ value: Any?) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            if let value {
                storage.addAttribute(key, value: value, range: range)
            } else {
                storage.removeAttribute(key, range: range)
            }
            Self.restyle(storage, in: range)
            didChangeText()
        }
        var typing = typingAttributes
        typing[key] = value
        typingAttributes = Self.visual(typing)
    }
    /// The styles over the text in UTF-16 ranges; a list item is one whole line, its newline included (as Google Chat sends it).
    var formatting: [TextStyleRange] {
        guard let storage = textStorage else { return [] }
        let string = storage.string as NSString
        var ranges: [TextStyleRange] = []
        for style in Self.styles {
            storage.enumerateAttribute(Self.key(style), in: NSRange(location: 0, length: storage.length)) {
                value, range, _ in
                guard value != nil else { return }
                // A code block or quote is one range over its lines, its last newline included unless it ends the message.
                guard style == .listItem else {
                    ranges.append(TextStyleRange(style: style, start: range.location, length: range.length))
                    return
                }
                string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) {
                    _, _, line, _ in
                    ranges.append(TextStyleRange(style: .listItem, start: line.location, length: line.length))
                }
            }
        }
        storage.enumerateAttribute(Self.colorKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let argb = value as? NSNumber {
                ranges.append(
                    TextStyleRange(style: .color(argb.uint32Value), start: range.location, length: range.length))
            }
        }
        storage.enumerateAttribute(Self.linkKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = value as? URL {
                ranges.append(TextStyleRange(style: .link(url), start: range.location, length: range.length))
            }
        }
        storage.enumerateAttribute(Self.mentionKey, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let token = value as? MentionToken else { return }
            let style: TextStyleRange.Style =
                token.app ? .appMention(userID: PersonID(token.userID)) : .mention(userID: PersonID(token.userID))
            ranges.append(TextStyleRange(style: style, start: range.location, length: range.length))
        }
        storage.enumerateAttribute(Self.chipKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let token = value as? MentionToken else { return }
            let chip = TextStyleRange.Style.chip(ConversationID(token.userID), emoji: token.emoji, link: token.link)
            ranges.append(TextStyleRange(style: chip, start: range.location, length: range.length))
        }
        storage.enumerateAttribute(Self.commandKey, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            if let command = value as? SlashCommand {
                ranges.append(
                    TextStyleRange(style: .slashCommand(command), start: range.location, length: range.length))
            }
        }
        storage.enumerateAttribute(Self.driveKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let file = value as? DriveFile {
                ranges.append(TextStyleRange(style: .drive(file), start: range.location, length: range.length))
            }
        }
        storage.enumerateAttribute(Self.customEmojiKey, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let emoji = value as? CustomEmoji else { return }  // equal neighbours share a run: one range each
            for index in range.location..<NSMaxRange(range) {
                ranges.append(TextStyleRange(style: .customEmoji(emoji), start: index, length: 1))
            }
        }
        guard hasMarkedText() else { return ranges }
        // Counted in `draftText`, which leaves the marked text out: ranges after it move back, ranges over it shrink.
        let marked = markedRange()
        return ranges.compactMap { range in
            let start = range.start
            let end = range.start + range.length
            func committed(_ index: Int) -> Int {
                index <= marked.location ? index : max(marked.location, index - marked.length)
            }
            let newStart = committed(start)
            let newEnd = committed(end)
            return newEnd > newStart
                ? TextStyleRange(style: range.style, start: newStart, length: newEnd - newStart) : nil
        }
    }
    /// The text as a draft holds it: each custom emoji (an attachment here) is the U+FFFD Google Chat sends for it, and
    /// only committed text: an input method's composition or an inline prediction (marked text) is not part of it until
    /// it is committed, or Return would send a half-typed word.
    var draftText: String {
        guard let storage = textStorage else { return string }
        let text = NSMutableString(string: storage.string)
        storage.enumerateAttribute(Self.customEmojiKey, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            if value != nil {
                text.replaceCharacters(in: range, with: String(repeating: "\u{FFFD}", count: range.length))
            }
        }
        if hasMarkedText(), NSMaxRange(markedRange()) <= text.length { text.deleteCharacters(in: markedRange()) }
        return text as String
    }
    /// Replaces the contents; styles the composer can't edit (headings, mentions with no user…) are dropped.
    func load(_ text: String, _ formatting: [TextStyleRange]) {
        let styled = NSMutableAttributedString(string: text)
        for range in formatting
        where Self.styles.contains(range.style) && range.start >= 0 && range.length > 0
            && range.start + range.length <= styled.length
        {
            styled.addAttribute(
                Self.key(range.style), value: true, range: NSRange(location: range.start, length: range.length))
        }
        for range in formatting
        where range.start >= 0 && range.length > 0 && range.start + range.length <= styled.length {
            let span = NSRange(location: range.start, length: range.length)
            if case .color(let argb) = range.style {
                styled.addAttribute(Self.colorKey, value: NSNumber(value: argb), range: span)
            }
            if case .link(let url) = range.style { styled.addAttribute(Self.linkKey, value: url, range: span) }
            if case .slashCommand(let command) = range.style {
                styled.addAttribute(Self.commandKey, value: command, range: span)
            }
            if case .drive(let file) = range.style { styled.addAttribute(Self.driveKey, value: file, range: span) }
            if case .chip(let room, let emoji, let link) = range.style {  // an edited message's chip stays a chip
                styled.addAttribute(
                    Self.chipKey,
                    value: MentionToken(
                        userID: room.rawValue, text: (text as NSString).substring(with: span), emoji: emoji, link: link),
                    range: span)
            }
        }
        for range in formatting
        where range.start >= 0 && range.length > 0 && range.start + range.length <= styled.length {
            let span = NSRange(location: range.start, length: range.length)
            let shown = (text as NSString).substring(with: span)
            if case .mention(let id?) = range.style {
                styled.addAttribute(Self.mentionKey, value: MentionToken(userID: id.rawValue, text: shown), range: span)
            }
            if case .appMention(let id) = range.style {
                styled.addAttribute(
                    Self.mentionKey, value: MentionToken(userID: id.rawValue, text: shown, app: true), range: span)
            }
        }
        for range in formatting.reversed() where range.start >= 0 && range.length == 1 && range.start < styled.length
        {  // one character each
            guard case .customEmoji(let emoji) = range.style else { continue }
            let span = NSRange(location: range.start, length: 1)
            styled.replaceCharacters(
                in: span,
                with: Self.customEmojiToken(
                    emoji, attributes: styled.attributes(at: span.location, effectiveRange: nil)))
        }
        Self.restyle(styled, in: NSRange(location: 0, length: styled.length))
        textStorage?.setAttributedString(styled)
        forgetTyping()
        if text.isEmpty { typingAttributes = Self.visual([:]) }  // a sent or cleared draft starts plain
        updateMention()
        loadCustomEmojiImages()
    }
    /// The typing's undo actions, once Parley replaces the text itself: they name ranges of the old text, and a sent
    /// message or another draft mustn't come back. The window's own actions (a pin, a mute) stay.
    private func forgetTyping() {
        breakUndoCoalescing()
        typingUndo.removeAllActions()
    }
    /// Toggles `style` over the selection (whole lines for lists), or for what is typed next at a caret.
    /// On or off follows the selection's first character, as TextEdit's toggles do.
    func toggle(_ style: TextStyleRange.Style) {
        guard let storage = textStorage else { return }
        let key = Self.key(style)
        var range = selectedRange()
        if Self.lineStyles.contains(style) { range = (string as NSString).paragraphRange(for: range) }
        let on =
            range.length > 0
            ? storage.attribute(key, at: range.location, effectiveRange: nil) == nil : typingAttributes[key] == nil
        if range.length > 0 {
            guard shouldChangeText(in: range, replacementString: nil) else { return }
            if on {
                storage.addAttribute(key, value: true, range: range)
            } else {
                storage.removeAttribute(key, range: range)
            }
            Self.restyle(storage, in: range)
            didChangeText()
        }
        var typing = typingAttributes
        typing[key] = on ? true : nil
        typingAttributes = Self.visual(typing)
    }
    /// Display attributes for a run carrying composer style keys.
    static func visual(_ attributes: [NSAttributedString.Key: Any], scale: CGFloat = TextSize.scale)
        -> [NSAttributedString.Key: Any]
    {
        var visual = attributes.filter { $0.key.rawValue.hasPrefix("Parley.composer.") }
        func has(_ style: TextStyleRange.Style) -> Bool { visual[key(style)] != nil }
        var font: NSFont =
            has(.code) || has(.codeBlock)
            ? .monospacedSystemFont(ofSize: 13 * scale, weight: .regular) : .systemFont(ofSize: 14 * scale)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if has(.bold) { traits.insert(.bold) }
        if has(.italic) { traits.insert(.italic) }
        if !traits.isEmpty {
            font =
                NSFont(
                    descriptor: font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(traits)), size: font.pointSize) ?? font
        }
        visual[.font] = font
        visual[.foregroundColor] = NSColor.textColor
        if tokenKeys.contains(where: { visual[$0] != nil }) { visual[.foregroundColor] = NSColor.controlAccentColor }
        if visual[customEmojiKey] != nil { visual[.attachment] = attributes[.attachment] }
        if has(.strike) { visual[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if has(.underline) { visual[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let argb = visual[colorKey] as? NSNumber {
            visual[.foregroundColor] = NSColor(rgb: argb.uint32Value & 0xFF_FFFF)
        }
        if visual[linkKey] != nil {
            visual[.foregroundColor] = NSColor.linkColor
            visual[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if has(.code) || has(.codeBlock) { visual[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
        if has(.quote) { visual[.foregroundColor] = NSColor.secondaryLabelColor }
        if has(.listItem) || has(.quote) || has(.codeBlock) {
            let indent = NSMutableParagraphStyle()
            indent.firstLineHeadIndent = 16
            indent.headIndent = 16
            visual[.paragraphStyle] = indent
        }
        return visual
    }
    /// View ▸ Bigger or Smaller: the draft and what's typed next take the new size.
    @objc func textSizeChanged() {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        Self.restyle(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        typingAttributes = Self.visual(typingAttributes)
        reportHeight()
    }
    static func restyle(_ text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttributes(in: range) { attributes, run, _ in text.setAttributes(visual(attributes), range: run) }
    }
}
