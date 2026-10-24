import AppKit
import ParleyDomain

/// The bubble's text: right-click opens the message menu (as on the rest of the bubble), not the text menu.
final class MessageTextView: NSTextView {
    /// Resizing a text view scrolls its insertion point into view; in the timeline that would scroll the whole table.
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
    var messageMenu: ((String?) -> NSMenu?)?
    var mentionMenu: ((PersonID, _ name: String) -> NSMenu?)?  // a click on a mention: that person's card
    var openChatLink: ((ChatLink, URL) async -> Bool)?  // Google Chat links open in Parley, not the browser
    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = link as? URL ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, let chat = ChatLink(url), openChatLink != nil else {
            return super.clicked(onLink: link, at: charIndex)
        }
        open(chat, url, at: lastClick)
    }
    /// Opens a Chat link in Parley; one this account can't open gets web's card where it was clicked, not the browser.
    private func open(_ chat: ChatLink, _ url: URL, at point: NSPoint) {
        guard let openChatLink, let window else { return }
        // Where it was clicked, in screen coordinates, taken now: by the time Parley knows, the row may be another's.
        let screen = window.convertToScreen(convert(NSRect(x: point.x, y: point.y - 8, width: 1, height: 16), to: nil))
        Task {
            guard await !openChatLink(chat, url) else { return }
            ChatLink.showRestricted(chat, above: screen, in: window)
        }
    }
    private var lastClick = NSPoint.zero
    /// A click on a mention pops its card up, on a chip opens its conversation; anywhere else selects text and follows
    /// links as usual.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastClick = point
        if let url = chip(at: point), let chat = ChatLink(url) { return open(chat, url, at: point) }
        guard let (id, name) = mention(at: point), let menu = mentionMenu?(id, name) else {
            return super.mouseDown(with: event)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }
    func chip(at point: NSPoint) -> URL? {
        characterIndex(at: point).flatMap {
            textStorage?.attribute(MessageTextStyle.chipKey, at: $0, effectiveRange: nil) as? URL
        }
    }
    /// The mention whose glyphs are under `point` (view coordinates): its user id and text without the "@".
    func mention(at point: NSPoint) -> (PersonID, String)? {
        guard let textStorage, let index = characterIndex(at: point) else { return nil }
        var range = NSRange()
        guard let id = textStorage.attribute(MessageTextStyle.mentionKey, at: index, effectiveRange: &range) as? String
        else { return nil }
        let text = (textStorage.string as NSString).substring(with: range)
        return (PersonID(id), text.hasPrefix("@") ? String(text.dropFirst()) : text)
    }
    /// The character whose glyph is under `point` (view coordinates); nil between and after glyphs.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
            layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(
                local)
        else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    // An emoji in the text shows the reaction pills' hover card: the emoji large and its :name:, as Google Chat web does.
    var loadAttachment: (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }  // custom emoji pictures
    private var hovered: NSRange?
    /// The emoji at `index`, standard or custom: its card and the characters it covers. Nil for any other character.
    func emojiCard(at index: Int) -> (content: ReactionCardView, range: NSRange)? {
        guard let textStorage, index >= 0, index < textStorage.length else { return nil }
        if let custom = textStorage.attribute(MessageTextStyle.emojiKey, at: index, effectiveRange: nil) as? CustomEmoji
        {
            return (
                ReactionCardView(
                    reaction: Reaction(emoji: custom.text, people: [], custom: custom), names: "", load: loadAttachment),
                NSRange(location: index, length: 1)
            )
        }
        let string = textStorage.string as NSString
        let range = string.rangeOfComposedCharacterSequence(at: index)
        let emoji = string.substring(with: range)
        guard let character = emoji.first, emoji.count == 1, character.isEmojiGlyph else { return nil }
        let name = (character.unicodeScalars.first?.properties.name ?? "").lowercased().replacingOccurrences(
            of: " ", with: "-")
        return (
            ReactionCardView(reaction: Reaction(emoji: emoji, people: []), names: ":\(name):", load: loadAttachment),
            range
        )
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self))
        }
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let card = characterIndex(at: convert(event.locationInWindow, from: nil)).flatMap(emojiCard)
        guard card?.range != hovered else { return }
        hovered = card?.range
        guard let card, let layoutManager, let textContainer else { return ReactionCard.shared.hide(self) }
        let glyphs = layoutManager.glyphRange(forCharacterRange: card.range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(
            dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        ReactionCard.shared.hover(self, card.content, at: rect)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = nil
        ReactionCard.shared.hide(self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let range = selectedRange()
        let selection = range.length > 0 ? (string as NSString).substring(with: range) : nil
        guard let menu = messageMenu?(selection) else { return super.menu(for: event) }
        // Selected text: the text's own items (Look Up, Translate, Search With Google, Share, Speech) follow ours.
        if selection != nil, let text = super.menu(for: event) {
            let wanted = text.items.filter { $0.isEnabled || $0.hasSubmenu || $0.isSeparatorItem }
            if !wanted.isEmpty { menu.addItem(.separator()) }
            for item in wanted {
                text.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }
    /// Pops the message menu up for the row, not for the text, so the system adds no text items to it; with text
    /// selected, for the text, so the system adds its items for the selection (Services).
    override func rightMouseDown(with event: NSEvent) {
        guard messageMenu != nil, let row = superview, let menu = menu(for: event) else {
            return super.rightMouseDown(with: event)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: selectedRange().length > 0 ? self : row)
    }
}

/// Message text's own drawing: text backgrounds (a chip's pill, inline code) with rounded corners, as Google Chat draws
/// them, and a quote's bar or a code block's background over every line of the block.
final class MessageLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let all = NSRange(location: 0, length: storage.length)
        let shown = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for key in [MessageTextStyle.codeFillKey, MessageTextStyle.quoteBarKey] {
            storage.enumerateAttribute(key, in: shown) { value, run, _ in
                guard let color = value as? NSColor else { return }
                var block = NSRange()  // the whole block, even when only part of it is being drawn
                _ = storage.attribute(key, at: run.location, longestEffectiveRange: &block, in: all)
                var lines = NSRect.null
                enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: block, actualCharacterRange: nil)) {
                    fragment, _, _, _, _ in
                    lines = lines.union(fragment)
                }
                guard !lines.isNull else { return }
                lines = lines.offsetBy(dx: origin.x, dy: origin.y)
                color.setFill()
                if key == MessageTextStyle.codeFillKey {
                    NSBezierPath(roundedRect: lines, xRadius: 6, yRadius: 6).fill()
                } else {
                    NSBezierPath(
                        roundedRect: NSRect(x: lines.minX, y: lines.minY, width: 3, height: lines.height), xRadius: 1.5,
                        yRadius: 1.5
                    ).fill()
                }
            }
        }
    }
    override func fillBackgroundRectArray(
        _ rects: UnsafePointer<NSRect>, count: Int, forCharacterRange range: NSRange, color: NSColor
    ) {
        let path = NSBezierPath()
        for index in 0..<count { path.append(NSBezierPath(roundedRect: rects[index], xRadius: 5, yRadius: 5)) }
        color.setFill()
        path.fill()
    }
}
