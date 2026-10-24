import AppKit
import ParleyDomain
import os

/// Sizes `CardView` draws at, known before any picture loads; `RowLayout` reserves the same.
enum CardLayout {
    static let pad: CGFloat = 10, gap: CGFloat = 6, icon: CGFloat = 24, iconGap: CGFloat = 8
    static let labelHeight: CGFloat = 15, labelGap: CGFloat = 2, buttons: CGFloat = 26, buttonIcon: CGFloat = 14,
        buttonIconGap: CGFloat = 4
    /// Inside the card's box; a bare card has none.
    static func inset(_ card: Card) -> CGFloat { card.bare == true ? 0 : pad }
    /// A button's width as `CardButtonStyle` draws it: its title, its icon, the padding; an icon-only one is round.
    static func buttonWidth(_ link: Card.Link) -> CGFloat {
        let icon = link.symbol != nil || link.icon != nil
        guard !link.title.isEmpty else { return buttons }
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
        let title = RowLayout.measure(
            RowLayout.styled(link.title, font, oneLine: true), width: .greatestFiniteMagnitude
        ).width
        return ceil(title + 24 + (icon ? buttonIcon + buttonIconGap : 0)) + 2
    }
    /// As wide as the row allows (the widest bubble, `RowLayout.maxBubble`), as web spreads a card across the message column.
    static func width(maxWidth: CGFloat) -> CGFloat { min(RowLayout.maxBubble, maxWidth) }
    static func textWidth(_ cardWidth: CGFloat, icon: Bool, button: Card.Link? = nil, toggle: Card.Toggle? = nil)
        -> CGFloat
    {
        cardWidth - 2 * pad - (icon ? Self.icon + iconGap : 0)
            - (button.map { buttonWidth($0) + iconGap } ?? toggle.map { toggleWidth($0) + iconGap } ?? 0)
    }
    /// A row's end switch, or its check box.
    static func toggleWidth(_ toggle: Card.Toggle) -> CGFloat { toggle.checkbox ? 16 : 44 }
    /// Inputs: a one-line control, a check box's or radio button's line.
    static let control: CGFloat = 22, option: CGFloat = 18, optionGap: CGFloat = 4
    /// A text field's height (`CardFieldStyle`): a line of text with 4 points above and below.
    static let fieldControl: CGFloat = 24
    /// A multi-line text field grows a line at a time, up to `maxLines`, then scrolls.
    static let maxLines = 5, fieldInset: CGFloat = 12
    private static var fieldFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
    /// The lines a multi-line field shows for its value in a slot `width` wide: one when empty.
    static func lines(_ field: Card.Field, width: CGFloat) -> Int {
        guard !field.value.isEmpty else { return 1 }
        let font = fieldFont
        let line = ceil(font.ascender - font.descender + font.leading)
        let height = RowLayout.measure(RowLayout.styled(field.value, font), width: max(1, width - fieldInset)).height
        return min(maxLines, max(1, Int((height / line).rounded())))
    }
    /// A text field's height: one control, and a line more for each extra line a multi-line one shows.
    static func fieldHeight(_ field: Card.Field, width: CGFloat) -> CGFloat {
        guard field.multiline == true else { return fieldControl }
        let font = fieldFont
        return fieldControl + CGFloat(lines(field, width: width) - 1)
            * ceil(font.ascender - font.descender + font.leading)
    }
    /// Room above and below the line between sections in a card without a box, whose sections have no padding of their
    /// own; a card that draws its own dividers has none between sections, only this room.
    static func sectionRoom(_ card: Card) -> CGFloat { card.bare == true ? 6 : 0 }
    static func betweenSections(_ card: Card) -> CGFloat { 2 * sectionRoom(card) + (card.dividers == false ? 0 : 1) }
    /// Room above and below a divider, so the widgets around it don't touch the line.
    static let dividerPad: CGFloat = 4
    /// Columns sit side by side from this card width, as Google Chat wraps them on narrow screens; `columnGap` apart.
    static let sideBySideWidth: CGFloat = 400, columnGap: CGFloat = 12
    static func sideBySide(_ cardWidth: CGFloat) -> Bool { cardWidth >= sideBySideWidth }
    /// A column's width inside a card of `cardWidth`: half of it side by side, all of it stacked.
    static func columnWidth(_ cardWidth: CGFloat) -> CGFloat {
        let inner = cardWidth - 2 * pad
        return sideBySide(cardWidth) ? floor((inner - columnGap) / 2) : inner
    }
    /// Whether an input keeps a line under it: for its hint, or to say what's wrong (required, too long, not a number).
    static func caption(_ item: Card.Item) -> Bool {
        switch item {
        case .field(let field): field.hint != nil || field.kind != nil || field.limit != nil || field.required == true
        case .choice(let choice): choice.required == true
        case .date(let date): date.required == true
        default: false
        }
    }
    /// An input's height: its label, its control, its caption line.
    private static func input(label: Bool, control: CGFloat, caption: Bool) -> CGFloat {
        (label ? labelHeight + labelGap : 0) + control + (caption ? labelGap + labelHeight : 0)
    }
    static let more: CGFloat = 18  // a cut paragraph's Show more / Show less
    static func height(_ item: Card.Item, width cardWidth: CGFloat, expanded: Bool = false, hugs: Bool = false)
        -> CGFloat
    {
        switch item {
        case .text(let text, let formatting, let lines):
            let width = textWidth(cardWidth, icon: false)
            guard let shown = cut(text, formatting, lines: lines, width: width) else {
                return NativeMessageText.size(of: text, formatting: formatting, width: width, lines: lines ?? 0).height
            }
            let body =
                expanded
                ? NativeMessageText.size(of: text, formatting: formatting, width: width)
                : NativeMessageText.size(of: shown, formatting: formatting, width: width, lines: lines ?? 0)
            return body.height + gap + more
        case .row(let icon, _, let label, let text, let formatting, _, let button, let toggle, _):
            let body = NativeMessageText.size(
                of: text, formatting: formatting,
                width: textWidth(cardWidth, icon: icon != nil, button: button, toggle: toggle)
            ).height
            return max(
                icon == nil ? 0 : Self.icon, button == nil && toggle == nil ? 0 : buttons,
                (label == nil ? 0 : labelHeight + labelGap) + body)
        case .links: return buttons
        case .collapse: return more
        case .image(let url, let aspect, _, _):
            return imageSize(url, aspect: aspect, slot: textWidth(cardWidth, icon: false), hugs: hugs).height
        case .divider: return 1 + 2 * dividerPad
        case .field(let field):
            return input(
                label: !field.label.isEmpty, control: fieldHeight(field, width: textWidth(cardWidth, icon: false)),
                caption: caption(item))
        case .choice(let choice):
            let count = CGFloat(choice.options.count)
            let body =
                choice.style == .menu || choice.style == .multiple
                ? control : count * option + max(0, count - 1) * optionGap
            return input(label: choice.label != nil, control: body, caption: caption(item))
        case .date(let date): return input(label: date.label != nil, control: control, caption: caption(item))
        case .columns(let columns):
            let inner = columnWidth(cardWidth)
            let heights = columns.map { column in
                column.map { height($0, width: inner + 2 * pad, expanded: expanded) }.reduce(0, +) + gap
                    * CGFloat(max(0, column.count - 1))
            }
            return sideBySide(cardWidth)
                ? heights.max() ?? 0 : heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1))
        }
    }
    /// A paragraph longer than its `lines` at `width`: its first lines ending in "…", as web cuts it (a cut at an empty
    /// line puts "…" there); nil when it fits or has no limit.
    nonisolated static func cut(_ text: String, _ formatting: [TextStyleRange], lines: Int?, width: CGFloat) -> String?
    {
        guard let lines, lines > 0 else { return nil }
        let storage = NSTextStorage(attributedString: MessageTextStyle.styled(text, formatting, own: false))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var count = 0
        var end = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, _, _, glyphs, stop in
            count += 1
            if count == lines {
                end = NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
                stop.pointee = true
            }
        }
        let all = storage.string as NSString
        guard count == lines, end < all.length else { return nil }
        var kept = all.substring(to: end)
        if kept.hasSuffix("\n") {
            kept.removeLast()
        } else {  // "with the…", not "with the …"
            while kept.last == " " { kept.removeLast() }
        }
        return kept + "…"
    }
    static let minFit: CGFloat = 120, tallest: CGFloat = 400
    /// Card pictures' sizes, kept between launches: the pictures are fetched again each launch, and a card that hugs its
    /// picture is then the right width before it arrives. Set once at launch (nil in tests and the demo workspaces).
    #if DEBUG
        nonisolated(unsafe) static var sizesFile: URL? = URL.cachesDirectory.appending(
            path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/card-picture-sizes-debug.plist")
    #else
        nonisolated(unsafe) static var sizesFile: URL? = URL.cachesDirectory.appending(
            path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/card-picture-sizes.plist")
    #endif
    private static let naturals = OSAllocatedUnfairLock<[URL: CGSize]>(initialState: sizes(in: sizesFile))
    /// The sizes saved in `file`, by picture URL.
    static func sizes(in file: URL?) -> [URL: CGSize] {
        guard let file, let data = try? Data(contentsOf: file),
            let saved = try? PropertyListDecoder().decode([String: [Double]].self, from: data)
        else { return [:] }
        return Dictionary(
            saved.compactMap { key, wh in
                URL(string: key).flatMap { wh.count == 2 ? ($0, CGSize(width: wh[0], height: wh[1])) : nil }
            }
        ) { $1 }
    }
    // ponytail: past 1,000 pictures the file is cleared, not trimmed by use; an LRU if cards ever churn that much.
    private static func save(_ sizes: [URL: CGSize]) {
        guard let file = sizesFile else { return }
        let saved = Dictionary(
            uniqueKeysWithValues: (sizes.count > 1_000 ? [:] : sizes).map {
                ($0.absoluteString, [$1.width, $1.height])
            })
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? PropertyListEncoder().encode(saved).write(to: file, options: .atomic)
        }
    }
    /// Posted (with the picture's URL) when a card's picture loads at a size not known before: cards that hug it re-measure.
    static let pictureSized = Notification.Name("CardLayout.pictureSized")
    /// A loaded picture's own size: what a card that is only a picture is as wide as. Measured with the rows, off the main actor.
    static func natural(_ url: URL) -> CGSize? { naturals.withLock { $0[url] } }
    @MainActor static func noteNatural(_ url: URL, _ size: CGSize) {
        guard size.width > 0, size.height > 0, naturals.withLock({ $0.updateValue(size, forKey: url) }) != size else {
            return
        }
        save(naturals.withLock { $0 })
        NotificationCenter.default.post(name: pictureSized, object: url)
    }
    /// A card of pictures and plain text, every picture's size known, has no more to fill a wide card with (`fitWidth`).
    static func hugs(_ card: Card) -> Bool {
        guard card.bare != true else { return false }
        var pictures = false
        for item in card.sections.joined() {
            switch item {
            case .image(let url, _, _, _):
                guard natural(url) != nil else { return false }
                pictures = true
            case .text, .divider, .row(nil, _, _, _, _, _, nil, nil, _): continue
            default: return false
            }
        }
        return pictures
    }
    /// A picture's drawn size in a slot: the slot's width at the card's aspect, up to 240 high; in a card that hugs
    /// it, its own size (never enlarged), scaled down to the slot and to `tallest`.
    static func imageSize(_ url: URL, aspect: Double, slot: CGFloat, hugs: Bool) -> CGSize {
        let aspect = CGFloat(max(0.2, aspect))
        guard hugs, let natural = natural(url) else { return CGSize(width: slot, height: min(240, slot / aspect)) }
        let width = natural.width * min(1, slot / natural.width, tallest * aspect / natural.width)
        return CGSize(width: width, height: width / aspect)
    }
    /// The width of a card that is only pictures and short text: the widest of them with the card's padding (at least
    /// `minFit`, at most the usual card width); nil when the card has more in it, or a picture isn't loaded yet.
    static func fitWidth(_ card: Card, maxWidth: CGFloat) -> CGFloat? {
        guard hugs(card) else { return nil }
        let full = width(maxWidth: maxWidth)
        var inner = minFit - 2 * pad
        for item in card.sections.joined() {
            switch item {
            case .image(let url, let aspect, _, _):
                inner = max(inner, imageSize(url, aspect: aspect, slot: full - 2 * pad, hugs: true).width)
            case .text(let text, let formatting, _), .row(_, _, _, let text, let formatting, _, _, _, _):
                inner = max(
                    inner,
                    NativeMessageText.size(of: text, formatting: formatting, width: .greatestFiniteMagnitude).width)
            default: break
            }
        }
        return min(full, ceil(inner) + 2 * pad)
    }
    static let byline: CGFloat = 18  // "By <app>" under a card
    static func size(_ card: Card, maxWidth: CGFloat, expanded: Bool = false) -> CGSize {
        let width = fitWidth(card, maxWidth: maxWidth) ?? width(maxWidth: maxWidth)
        return CGSize(
            width: width,
            height: boxHeight(card, width: width, expanded: expanded) + (card.by == nil ? 0 : gap + byline))
    }
    /// The card's own box, without the byline under it.
    static func boxHeight(_ card: Card, width: CGFloat, expanded: Bool = false) -> CGFloat {
        let inset = inset(card)
        let fit = hugs(card)
        let sections = card.sections.map { section in
            let items = Card.shown(section, expanded: expanded)
            return 2 * inset
                + items.map { height($0, width: width + 2 * (pad - inset), expanded: expanded, hugs: fit) }.reduce(0, +)
                + gap * CGFloat(max(0, items.count - 1))
        }
        return ceil(sections.reduce(0, +) + CGFloat(max(0, sections.count - 1)) * betweenSections(card))
    }
}
