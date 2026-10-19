import os
import SwiftUI

/// An app's card under its message, as Google Chat draws it: sections split by lines (a collapsible one with its
/// toggle), rows with an icon (round for a person), a small label, text and an end button, pictures, and buttons that
/// open a link or send their action. A bare card (the buttons an app puts under its message) has no box.
struct CardView: View {
    let card: Card
    var dismiss: () -> Void = {}
    var expanded = false          // a cut paragraph shows all of it ("Show more")
    var toggle: () -> Void = {}   // Show more / Show less
    /// Sends a button's action with the card's inputs (`ChatStore.clickCard`).
    var click: (Data, [Card.Input]) async -> Void = { _, _ in }
    /// A dialog's own buttons: the card then scrolls over them, and they send its inputs like the card's buttons.
    var footer: (primary: Card.Link?, secondary: Card.Link?)? = nil
    var problem: String? = nil    // in a dialog: what the app said is wrong, over its buttons
    @State private var values: [String: [String]] = [:]   // the card's inputs as changed here, by name (`Card.form` has the rest)
    @State private var dates: [String: Date] = [:]        // a date picker's moment, once chosen here
    @State private var missing: Set<String> = []           // required inputs left empty when an action was tried
    @State private var pending: Card.Link?                 // a button whose action is on its way
    @Environment(\.openURL) private var openURL
    var body: some View {
        if let footer { sheet(primary: footer.primary, secondary: footer.secondary) } else {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: CardLayout.gap) {
                    box.frame(height: CardLayout.boxHeight(card, width: geometry.size.width, expanded: expanded))
                    if let by = card.by { byline(by) }
                }
            }
        }
    }
    /// As a dialog: the card scrolling, what's wrong, and the buttons fixed under it (secondary leading, primary the
    /// default button, ⏎), as Google Chat lays out a dialog.
    private func sheet(primary: Card.Link?, secondary: Card.Link?) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - 2 * DialogLayout.margin)
                ScrollView {
                    box.frame(width: width, height: CardLayout.boxHeight(drawn, width: width, expanded: expanded)).padding(DialogLayout.margin)
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DialogLayout.margin).frame(height: DialogLayout.problem)
            }
            Divider()
            HStack(spacing: 8) {
                if let secondary { button(secondary) }
                Spacer(minLength: 0)
                if let primary { button(primary).keyboardShortcut(.defaultAction) }
            }
            .padding(.horizontal, DialogLayout.margin).frame(height: DialogLayout.footer)
        }
    }
    /// "By <app>" and an App badge under the card, as Google Chat credits the app that made it.
    private func byline(_ by: Card.Attribution) -> some View {
        HStack(spacing: 6) {
            if let icon = by.icon { CardIcon(url: icon, round: false, size: 16) }
            Text(Self.bylineText(by.name)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("App").font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: CardLayout.byline)
    }
    /// "By" regular and the app's name bold, as web writes it.
    static func bylineText(_ name: String) -> AttributedString {
        var bold = AttributedString(name); bold.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("By ") + bold
    }
    /// The card as drawn: in a dialog, its text fields hold what was typed, so a multi-line one grows with it.
    private var drawn: Card {
        guard footer != nil, !values.isEmpty else { return card }
        func typed(_ item: Card.Item) -> Card.Item {
            switch item {
            case .field(var field): field.value = values[field.name]?.first ?? field.value; return .field(field)
            case .columns(let columns): return .columns(columns.map { $0.map(typed) })
            default: return item
            }
        }
        var card = card; card.sections = card.sections.map { $0.map(typed) }; return card
    }
    private var box: some View {
        let card = drawn, inset = CardLayout.inset(card), bare = card.bare == true, room = CardLayout.sectionRoom(card), hugs = CardLayout.hugs(card)
        return GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 {   // a line between sections, unless the card draws its own, with room round it
                        if card.dividers == false { Color.clear.frame(height: 2 * room) } else { Divider().padding(.vertical, room) }
                    }
                    VStack(alignment: .leading, spacing: CardLayout.gap) {
                        ForEach(Array(Card.shown(section, expanded: expanded).enumerated()), id: \.offset) { _, item in
                            // Each item in a slot of the card's current width, leading: never centred, so content
                            // sized for an older, wider card can't push in from the left.
                            itemView(item, width: geometry.size.width - 2 * inset)
                                .frame(width: geometry.size.width - 2 * inset,
                                       height: CardLayout.height(item, width: geometry.size.width + 2 * (CardLayout.pad - inset), expanded: expanded, hugs: hugs), alignment: .topLeading)
                        }
                    }
                    .padding(inset)
                }
            }
        }
        .background(bare ? Color.clear : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { if !bare { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) } }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func itemView(_ item: Card.Item, width: CGFloat) -> some View {
        switch item {
        case .text(let text, let formatting, let lines):
            if let shown = CardLayout.cut(text, formatting, lines: lines, width: width) {   // cut: "…", and Show more under it
                VStack(alignment: .leading, spacing: CardLayout.gap) {
                    NativeMessageText(text: expanded ? text : shown, formatting: formatting, own: false, lines: expanded ? 0 : lines ?? 0, maxWidth: width)
                    Button(expanded ? "Show less" : "Show more", action: toggle).buttonStyle(.link).frame(height: CardLayout.more)
                }
                .frame(width: width, alignment: .leading)
            } else {
                NativeMessageText(text: text, formatting: formatting, own: false, lines: lines ?? 0, maxWidth: width).frame(width: width, alignment: .leading)
            }
        case .row(let icon, let round, let label, let text, let formatting, let open, let end, let toggle, let alt):
            HStack(alignment: .top, spacing: CardLayout.iconGap) {
                if let icon { CardIcon(url: icon, round: round).accessibilityLabel(alt ?? "") }
                VStack(alignment: .leading, spacing: CardLayout.labelGap) {
                    if let label { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: CardLayout.labelHeight) }
                    NativeMessageText(text: text, formatting: formatting, own: false, maxWidth: CardLayout.textWidth(width + 2 * CardLayout.pad, icon: icon != nil, button: end, toggle: toggle))
                        .frame(maxWidth: .infinity, alignment: .leading)   // the proposed width, cut with "…" when it doesn't wrap
                }
                .overlay {   // the row's on-click: anywhere on it (but its button) opens it
                    if let open { Link(destination: open) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).help(open.absoluteString) }
                }
                if let end {   // the end button, centred on the row, as web draws a poll's Vote
                    button(end).frame(width: CardLayout.buttonWidth(end), height: CardLayout.height(item, width: width + 2 * CardLayout.pad))
                } else if let toggle {   // a switch (or check box) at the row's end: its value goes with the card's actions while on
                    Toggle(isOn: Binding(get: { (values[toggle.name] ?? (toggle.on ? [toggle.value] : [])).isEmpty == false },
                                         set: { values[toggle.name] = $0 ? [toggle.value] : [] })) { Text(text) }
                        .labelsHidden().toggleStyle(checkbox: toggle.checkbox).controlSize(.small)
                        .frame(width: CardLayout.toggleWidth(toggle), height: CardLayout.height(item, width: width + 2 * CardLayout.pad))
                }
            }
            .frame(width: width, alignment: .leading)
        case .links(let links):
            HStack(spacing: 8) {
                if let title = card.dismiss { Button(title, action: dismiss).buttonStyle(CardButtonStyle(link: nil)) }
                ForEach(links.filter { $0.trailing != true }, id: \.self, content: button)
                Spacer(minLength: 0)
                ForEach(links.filter { $0.trailing == true }, id: \.self, content: button)
            }
            .frame(width: width)
        case .image(let url, let aspect, let click, let alt):
            CardImage(url: url, alt: alt).frame(width: CardLayout.imageSize(url, aspect: aspect, slot: width, hugs: CardLayout.hugs(drawn)).width)
                .overlay {   // a click opens its link or sends its action
                    if let click {
                        if let action = click.action { Button { send(action, from: click) } label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain) }
                        else { Link(destination: click.url) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).help(click.url.absoluteString) }
                    }
                }
        case .divider:
            Divider().frame(width: width).padding(.vertical, CardLayout.dividerPad)
        case .field(let field):
            input(label: field.label.isEmpty ? nil : field.label, caption: CardLayout.caption(item), problem: problem(field), hint: field.hint, width: width) {
                let text = Binding(get: { values[field.name]?.first ?? field.value }, set: { values[field.name] = [$0]; missing.remove(field.name) })
                if field.multiline == true {   // one line high, growing with what's typed
                    TextField(field.placeholder ?? "", text: text, axis: .vertical).lineLimit(1...CardLayout.lines(field, width: width))
                        .modifier(CardFieldStyle(height: CardLayout.fieldHeight(field, width: width)))
                } else {
                    TextField(field.placeholder ?? "", text: text).modifier(CardFieldStyle(height: CardLayout.fieldControl))
                }
            }
        case .choice(let choice):
            input(label: choice.label, caption: CardLayout.caption(item), problem: missing.contains(choice.name) ? "Required" : nil, hint: nil, width: width) {
                CardChoice(choice: choice, picked: Binding(get: { values[choice.name] ?? card.form.first { $0.name == choice.name }?.values ?? [] },
                                                           set: { values[choice.name] = $0; missing.remove(choice.name) }))
            }
        case .date(let date):
            input(label: date.label, caption: CardLayout.caption(item), problem: missing.contains(date.name) ? "Required" : nil, hint: nil, width: width) {
                dateView(date)
            }
        case .columns(let columns):
            let side = CardLayout.sideBySide(width + 2 * CardLayout.pad), inner = CardLayout.columnWidth(width + 2 * CardLayout.pad)
            let layout = side ? AnyLayout(HStackLayout(alignment: .top, spacing: CardLayout.columnGap)) : AnyLayout(VStackLayout(alignment: .leading, spacing: CardLayout.gap))
            layout {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: CardLayout.gap) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, part in
                            AnyView(itemView(part, width: inner)).frame(width: inner, height: CardLayout.height(part, width: inner + 2 * CardLayout.pad), alignment: .topLeading)
                        }
                    }
                    .frame(width: inner, alignment: .topLeading)
                }
            }
            .frame(width: width, alignment: .topLeading)
        case .collapse(let more, let less, _):   // a collapsible section's toggle: a disclosure chevron, as Google Chat draws it
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(expanded ? less : more).fontWeight(.medium)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).frame(height: CardLayout.more)
            .accessibilityElement(children: .ignore).accessibilityLabel(expanded ? less : more)
            .accessibilityValue(expanded ? "expanded" : "collapsed").accessibilityAddTraits(.isButton)
        }
    }
}

extension CardView {
    /// The card's inputs as they stand, in order: what was changed here, else what arrived.
    private var form: [(name: String, values: [String])] { card.form.map { ($0.name, values[$0.name] ?? $0.values) } }
    /// Sends `action` with the card's inputs; the answer replaces the message. Not while an input the action needs is
    /// empty or a text field holds what it can't: those say so under them, as Google Chat does.
    private func send(_ action: Data, from link: Card.Link) {
        let form = form
        let inputs = card.allItems.compactMap { item -> String? in   // what can be required: not a row's switch, which may be off
            switch item { case .field(let field): field.name; case .choice(let choice): choice.name; case .date(let date): date.name; default: nil }
        }
        let needed = link.required == ["*"] ? Set(inputs) : Set(link.required ?? [])
        missing = Set(form.filter { needed.contains($0.name) && $0.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }.map(\.name))
        let fields = card.allItems.compactMap { if case .field(let field) = $0 { field } else { nil } }
        guard missing.isEmpty, !fields.contains(where: { problem($0) != nil }) else { return }
        let sent = form.flatMap { name, values in values.map { Card.Input(name: name, value: $0) } }
        pending = link
        // A dialog keeps what was typed (the app may say what's wrong with it); its next step is a new card.
        Task { await click(action, sent); pending = nil; if footer == nil { values = [:]; dates = [:] } }
    }
    /// What's wrong with a text field's value, in Google Chat's words; nil: nothing.
    private func problem(_ field: Card.Field) -> String? {
        if missing.contains(field.name) { return "Required" }
        let value = (values[field.name]?.first ?? field.value).trimmingCharacters(in: .whitespaces)
        if let limit = field.limit, value.count > limit { return "\(value.count)/\(limit) characters" }
        guard !value.isEmpty else { return nil }
        switch field.kind {
        case .integer: return Int(value) == nil ? "Enter a whole number" : nil
        case .number: return Double(value) == nil ? "Enter a number" : nil
        case .email: return value.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) == nil ? "Enter an email address" : nil
        case nil: return nil
        }
    }
    /// An input with its label above it and, when it has room for one, its hint or what's wrong under it.
    private func input(label: String?, caption: Bool, problem: String?, hint: String?, width: CGFloat, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CardLayout.labelGap) {
            if let label { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: CardLayout.labelHeight) }
            control()
            if caption {
                Text(problem ?? hint ?? "").font(.caption).foregroundStyle(problem == nil ? Color.secondary : Color.red).lineLimit(1)
                    .frame(height: CardLayout.labelHeight)
            }
        }
        .frame(width: width, alignment: .leading)
    }
    /// A date, a time or both, in the viewer's time zone; one not chosen yet offers to set it.
    @ViewBuilder private func dateView(_ date: Card.DateField) -> some View {
        let initial = date.ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if let shown = dates[date.name] ?? initial {
            let components: DatePickerComponents = switch date.kind { case .date: .date; case .time: .hourAndMinute; case .dateAndTime: [.date, .hourAndMinute] }
            DatePicker("", selection: Binding(get: { shown }, set: { pick($0, for: date) }), displayedComponents: components)
                .datePickerStyle(.field).labelsHidden().frame(height: CardLayout.control)
        } else {
            Button(date.kind == .time ? "Set a time" : "Set a date") { pick(.now, for: date) }.buttonStyle(.link).frame(height: CardLayout.control)
        }
    }
    private func pick(_ moment: Date, for date: Card.DateField) {
        dates[date.name] = moment
        values[date.name] = [Card.dateValue(Int64((moment.timeIntervalSince1970 * 1000).rounded()), date.kind)]
        missing.remove(date.name)
    }
    /// A menu item's choice: its link opens, or its action goes to the app.
    private func run(_ link: Card.Link) {
        if let action = link.action { send(action, from: link) } else { openURL(link.url) }
    }
    @ViewBuilder private func button(_ link: Card.Link) -> some View {
        let style = CardButtonStyle(link: link), help = link.alt ?? (link.action == nil ? link.url.absoluteString : link.title)
        if let menu = link.menu, link.disabled != true {   // an overflow menu: its items, each doing its own thing
            Menu {
                ForEach(menu, id: \.self) { item in Button(item.title) { run(item.link) }.disabled(item.link.disabled == true) }
            } label: { label(link) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(pending != nil).help(help).accessibilityLabel(link.alt ?? link.title)
        } else if link.disabled == true {   // greyed, and nothing happens
            Button {} label: { label(link) }.buttonStyle(style).disabled(true).help(help).accessibilityLabel(link.alt ?? link.title)
        } else if let action = link.action {   // sent from here: the card's inputs go with it, and the answer replaces the message
            Button { send(action, from: link) } label: {
                if pending == link { ProgressView().controlSize(.small) } else { label(link) }
            }
            .buttonStyle(style).disabled(pending != nil).help(help).accessibilityLabel(link.alt ?? link.title)
        } else {
            Link(destination: link.url) { label(link) }.buttonStyle(style).help(help).accessibilityLabel(link.alt ?? link.title)
        }
    }
    /// The icon (a symbol, else its picture) and the title.
    private func label(_ link: Card.Link) -> some View {
        HStack(spacing: CardLayout.buttonIconGap) {
            if let symbol = link.symbol { Image(systemName: symbol).frame(width: CardLayout.buttonIcon) }
            else if let icon = link.icon { CardIcon(url: icon, round: false, size: CardLayout.buttonIcon, template: true) }
            if !link.title.isEmpty { Text(link.title).lineLimit(1) }
        }
    }
}
/// A card's button as Google Chat draws it: outlined (a thin grey rounded border, the title in the accent colour, no
/// fill), filled (in the accent colour or the button's own), tonal (a light wash of the accent colour), or borderless;
/// greyed when disabled. An icon-only button is a borderless circle.
private struct CardButtonStyle: ButtonStyle {
    let link: Card.Link?
    var filled: Bool { link?.filled == true }
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fill = link?.color.map { Color(nsColor: NSColor(rgb: $0 & 0xFF_FFFF)) } ?? Color.accentColor
        let iconOnly = link?.title.isEmpty == true, bordered = !filled && link?.look == nil && !iconOnly
        return configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(filled ? Color.white : iconOnly ? Color.secondary : Color.accentColor)
            .padding(.horizontal, iconOnly ? 0 : 12).frame(minWidth: iconOnly ? CardLayout.buttons : nil).frame(height: CardLayout.buttons - 2)
            .background(filled ? fill : link?.look == .tonal ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
            .overlay { if bordered { Capsule().strokeBorder(Color(nsColor: .separatorColor)) } }
            .contentShape(Capsule())
            .opacity(!enabled && link?.disabled == true ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

/// A card row's icon: a file type, an app, or a person's photo (round); a button's icon takes its colour (`template`).
private struct CardIcon: View {
    let url: URL
    let round: Bool
    var size = CardLayout.icon
    var template = false
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).renderingMode(template ? .template : .original).resizable().scaledToFill() }
            else { Color.secondary.opacity(template ? 0 : 0.15) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : 4))
        .task(id: url) { image = await RemoteImage.image(url, px: 64) }
    }
}

/// A card's picture, filling its width at the card's aspect ratio (a placeholder until it loads); a GIF animates. It
/// loads as the card names it: a size suffix would make Google's image proxy crop and enlarge a GIF.
private struct CardImage: View {
    let url: URL
    var alt: String?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                if image.animated { AnimatedImage(image: image) } else { Image(nsImage: image).resizable().scaledToFill() }
            } else { Color.secondary.opacity(0.15) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(alt ?? "Picture")
        .task(id: url) {
            image = await RemoteImage.image(url, px: 0)
            if let image { CardLayout.noteNatural(url, image.size) }
        }
    }
}
extension NSImage {
    /// More than one frame: a GIF (or animated PNG) that moves.
    var animated: Bool { animatedRep != nil }
    private var animatedRep: NSBitmapImageRep? {
        representations.lazy.compactMap { $0 as? NSBitmapImageRep }.first { ($0.value(forProperty: .frameCount) as? Int ?? 1) > 1 }
    }
    /// Draws the frame showing at `time` (seconds on a shared clock, so every copy of an emoji moves together), or the
    /// first one with Reduce Motion on. For pictures drawn inside text (custom emoji in a message or a reaction pill),
    /// which NSImageView can't animate; the view redraws while one shows.
    @MainActor func drawFrame(in rect: NSRect, at time: TimeInterval = Date.now.timeIntervalSinceReferenceDate) {
        guard let rep = animatedRep else { draw(in: rect); return }
        let frame = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.frame(durations: Self.durations(rep), at: time)
        rep.setProperty(.currentFrame, withValue: frame)
        rep.draw(in: rect)
    }
    /// Which frame shows `time` seconds into a loop of these durations.
    nonisolated static func frame(durations: [TimeInterval], at time: TimeInterval) -> Int {
        let loop = durations.reduce(0, +)
        guard loop > 0 else { return 0 }
        var left = time.truncatingRemainder(dividingBy: loop)
        for (index, duration) in durations.enumerated() {
            if left < duration { return index }
            left -= duration
        }
        return durations.count - 1
    }
    /// As browsers play GIFs: a frame of under 20 ms (often 0, "as fast as possible") shows for 100 ms.
    nonisolated static func playable(_ durations: [TimeInterval]) -> [TimeInterval] { durations.map { $0 < 0.02 ? 0.1 : $0 } }
    @MainActor private static let frameDurations = NSMapTable<NSBitmapImageRep, NSArray>.weakToStrongObjects()
    @MainActor private static func durations(_ rep: NSBitmapImageRep) -> [TimeInterval] {
        if let known = frameDurations.object(forKey: rep) as? [TimeInterval] { return known }
        let count = rep.value(forProperty: .frameCount) as? Int ?? 1
        let durations = playable((0..<count).map { frame in
            rep.setProperty(.currentFrame, withValue: frame)
            return (rep.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1
        })
        frameDurations.setObject(durations as NSArray, forKey: rep)
        return durations
    }
}

/// Sizes `CardView` draws at, known before any picture loads; `RowLayout` reserves the same.
enum CardLayout {
    static let pad: CGFloat = 10, gap: CGFloat = 6, icon: CGFloat = 24, iconGap: CGFloat = 8
    static let labelHeight: CGFloat = 15, labelGap: CGFloat = 2, buttons: CGFloat = 26, buttonIcon: CGFloat = 14, buttonIconGap: CGFloat = 4
    /// Inside the card's box; a bare card has none.
    static func inset(_ card: Card) -> CGFloat { card.bare == true ? 0 : pad }
    /// A button's width as `CardButtonStyle` draws it: its title, its icon, the padding; an icon-only one is round.
    static func buttonWidth(_ link: Card.Link) -> CGFloat {
        let icon = link.symbol != nil || link.icon != nil
        guard !link.title.isEmpty else { return buttons }
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
        let title = RowLayout.measure(RowLayout.styled(link.title, font, oneLine: true), width: .greatestFiniteMagnitude).width
        return ceil(title + 24 + (icon ? buttonIcon + buttonIconGap : 0)) + 2
    }
    /// As wide as the row allows (the widest bubble, `RowLayout.maxBubble`), as web spreads a card across the message column.
    static func width(maxWidth: CGFloat) -> CGFloat { min(RowLayout.maxBubble, maxWidth) }
    static func textWidth(_ cardWidth: CGFloat, icon: Bool, button: Card.Link? = nil, toggle: Card.Toggle? = nil) -> CGFloat {
        cardWidth - 2 * pad - (icon ? Self.icon + iconGap : 0) - (button.map { buttonWidth($0) + iconGap } ?? toggle.map { toggleWidth($0) + iconGap } ?? 0)
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
        let font = fieldFont, line = ceil(font.ascender - font.descender + font.leading)
        let height = RowLayout.measure(RowLayout.styled(field.value, font), width: max(1, width - fieldInset)).height
        return min(maxLines, max(1, Int((height / line).rounded())))
    }
    /// A text field's height: one control, and a line more for each extra line a multi-line one shows.
    static func fieldHeight(_ field: Card.Field, width: CGFloat) -> CGFloat {
        guard field.multiline == true else { return fieldControl }
        let font = fieldFont
        return fieldControl + CGFloat(lines(field, width: width) - 1) * ceil(font.ascender - font.descender + font.leading)
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
    static let more: CGFloat = 18   // a cut paragraph's Show more / Show less
    static func height(_ item: Card.Item, width cardWidth: CGFloat, expanded: Bool = false, hugs: Bool = false) -> CGFloat {
        switch item {
        case .text(let text, let formatting, let lines):
            let width = textWidth(cardWidth, icon: false)
            guard let shown = cut(text, formatting, lines: lines, width: width) else {
                return NativeMessageText.size(of: text, formatting: formatting, width: width, lines: lines ?? 0).height
            }
            let body = expanded ? NativeMessageText.size(of: text, formatting: formatting, width: width)
                : NativeMessageText.size(of: shown, formatting: formatting, width: width, lines: lines ?? 0)
            return body.height + gap + more
        case .row(let icon, _, let label, let text, let formatting, _, let button, let toggle, _):
            let body = NativeMessageText.size(of: text, formatting: formatting, width: textWidth(cardWidth, icon: icon != nil, button: button, toggle: toggle)).height
            return max(icon == nil ? 0 : Self.icon, button == nil && toggle == nil ? 0 : buttons, (label == nil ? 0 : labelHeight + labelGap) + body)
        case .links: return buttons
        case .collapse: return more
        case .image(let url, let aspect, _, _): return imageSize(url, aspect: aspect, slot: textWidth(cardWidth, icon: false), hugs: hugs).height
        case .divider: return 1 + 2 * dividerPad
        case .field(let field):
            return input(label: !field.label.isEmpty, control: fieldHeight(field, width: textWidth(cardWidth, icon: false)), caption: caption(item))
        case .choice(let choice):
            let count = CGFloat(choice.options.count)
            let body = choice.style == .menu || choice.style == .multiple ? control : count * option + max(0, count - 1) * optionGap
            return input(label: choice.label != nil, control: body, caption: caption(item))
        case .date(let date): return input(label: date.label != nil, control: control, caption: caption(item))
        case .columns(let columns):
            let inner = columnWidth(cardWidth)
            let heights = columns.map { column in
                column.map { height($0, width: inner + 2 * pad, expanded: expanded) }.reduce(0, +) + gap * CGFloat(max(0, column.count - 1))
            }
            return sideBySide(cardWidth) ? heights.max() ?? 0 : heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1))
        }
    }
    /// A paragraph longer than its `lines` at `width`: its first lines ending in "…", as web cuts it (a cut at an empty
    /// line puts "…" there); nil when it fits or has no limit.
    nonisolated static func cut(_ text: String, _ formatting: [TextStyleRange], lines: Int?, width: CGFloat) -> String? {
        guard let lines, lines > 0 else { return nil }
        let storage = NSTextStorage(attributedString: MessageTextStyle.styled(text, formatting, own: false))
        let manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        var count = 0, end = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, stop in
            count += 1
            if count == lines { end = NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)); stop.pointee = true }
        }
        let all = storage.string as NSString
        guard count == lines, end < all.length else { return nil }
        var kept = all.substring(to: end)
        if kept.hasSuffix("\n") { kept.removeLast() }
        else { while kept.last == " " { kept.removeLast() } }   // "with the…", not "with the …"
        return kept + "…"
    }
    static let minFit: CGFloat = 120, tallest: CGFloat = 400
    /// Card pictures' sizes, kept between launches: the pictures are fetched again each launch, and a card that hugs its
    /// picture is then the right width before it arrives. Set once at launch (nil in tests and the demo workspaces).
    #if DEBUG
    nonisolated(unsafe) static var sizesFile: URL? = URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/card-picture-sizes-debug.plist")
    #else
    nonisolated(unsafe) static var sizesFile: URL? = URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/card-picture-sizes.plist")
    #endif
    private static let naturals = OSAllocatedUnfairLock<[URL: CGSize]>(initialState: sizes(in: sizesFile))
    /// The sizes saved in `file`, by picture URL.
    static func sizes(in file: URL?) -> [URL: CGSize] {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? PropertyListDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return Dictionary(saved.compactMap { key, wh in URL(string: key).flatMap { wh.count == 2 ? ($0, CGSize(width: wh[0], height: wh[1])) : nil } }) { $1 }
    }
    // ponytail: past 1,000 pictures the file is cleared, not trimmed by use; an LRU if cards ever churn that much.
    private static func save(_ sizes: [URL: CGSize]) {
        guard let file = sizesFile else { return }
        let saved = Dictionary(uniqueKeysWithValues: (sizes.count > 1_000 ? [:] : sizes).map { ($0.absoluteString, [$1.width, $1.height]) })
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? PropertyListEncoder().encode(saved).write(to: file, options: .atomic)
        }
    }
    /// Posted (with the picture's URL) when a card's picture loads at a size not known before: cards that hug it re-measure.
    static let pictureSized = Notification.Name("CardLayout.pictureSized")
    /// A loaded picture's own size: what a card that is only a picture is as wide as. Measured with the rows, off the main actor.
    static func natural(_ url: URL) -> CGSize? { naturals.withLock { $0[url] } }
    @MainActor static func noteNatural(_ url: URL, _ size: CGSize) {
        guard size.width > 0, size.height > 0, naturals.withLock({ $0.updateValue(size, forKey: url) }) != size else { return }
        save(naturals.withLock { $0 })
        NotificationCenter.default.post(name: pictureSized, object: url)
    }
    /// A card of pictures and plain text, every picture's size known, has no more to fill a wide card with (`fitWidth`).
    static func hugs(_ card: Card) -> Bool {
        guard card.bare != true else { return false }
        var pictures = false
        for item in card.sections.joined() {
            switch item {
            case .image(let url, _, _, _): guard natural(url) != nil else { return false }; pictures = true
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
            case .image(let url, let aspect, _, _): inner = max(inner, imageSize(url, aspect: aspect, slot: full - 2 * pad, hugs: true).width)
            case .text(let text, let formatting, _), .row(_, _, _, let text, let formatting, _, _, _, _):
                inner = max(inner, NativeMessageText.size(of: text, formatting: formatting, width: .greatestFiniteMagnitude).width)
            default: break
            }
        }
        return min(full, ceil(inner) + 2 * pad)
    }
    static let byline: CGFloat = 18   // "By <app>" under a card
    static func size(_ card: Card, maxWidth: CGFloat, expanded: Bool = false) -> CGSize {
        let width = fitWidth(card, maxWidth: maxWidth) ?? width(maxWidth: maxWidth)
        return CGSize(width: width, height: boxHeight(card, width: width, expanded: expanded) + (card.by == nil ? 0 : gap + byline))
    }
    /// The card's own box, without the byline under it.
    static func boxHeight(_ card: Card, width: CGFloat, expanded: Bool = false) -> CGFloat {
        let inset = inset(card), fit = hugs(card)
        let sections = card.sections.map { section in
            let items = Card.shown(section, expanded: expanded)
            return 2 * inset + items.map { height($0, width: width + 2 * (pad - inset), expanded: expanded, hugs: fit) }.reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
        }
        return ceil(sections.reduce(0, +) + CGFloat(max(0, sections.count - 1)) * betweenSections(card))
    }
}

/// A card's text field as a Mac form draws one: the text on the text background inside one hairline rounded edge, alike
/// in light and dark (a rounded-border field's own edge barely shows on a white card in light mode).
private struct CardFieldStyle: ViewModifier {
    let height: CGFloat
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .padding(.horizontal, CardLayout.fieldInset / 2).padding(.vertical, 4)
            .frame(height: height, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)) }
    }
}

private extension View {
    /// A check box or a switch.
    @ViewBuilder func toggleStyle(checkbox: Bool) -> some View {
        if checkbox { toggleStyle(.checkbox) } else { toggleStyle(.switch) }
    }
}

/// A selection input as the Mac draws one: check boxes, radio buttons, switches, a pop-up menu, or a menu of check marks
/// for a multiple choice (at most `limit` picked). `picked` holds the picked options' values, in the options' order.
struct CardChoice: View {
    let choice: Card.Choice
    @Binding var picked: [String]
    var body: some View {
        switch choice.style {
        case .checkbox, .switches:
            VStack(alignment: .leading, spacing: CardLayout.optionGap) {
                ForEach(choice.options, id: \.value) { option in
                    Toggle(isOn: binding(option)) { title(option).lineLimit(1) }
                        .toggleStyle(checkbox: choice.style == .checkbox).controlSize(.small).frame(height: CardLayout.option)
                }
            }
        case .radio:
            Picker("", selection: one) { ForEach(choice.options, id: \.value) { title($0).tag($0.value) } }
                .pickerStyle(.radioGroup).labelsHidden()
        case .menu:
            Picker("", selection: one) { ForEach(choice.options, id: \.value) { Text($0.text).tag($0.value) } }
                .pickerStyle(.menu).labelsHidden().frame(height: CardLayout.control)
        case .multiple:
            Menu {
                ForEach(choice.options, id: \.value) { option in
                    Toggle(option.text, isOn: binding(option))
                        .disabled(!picked.contains(option.value) && choice.limit.map { picked.count >= $0 } == true)
                }
            } label: {
                let names = choice.options.filter { picked.contains($0.value) }.map(\.text)
                Text(names.isEmpty ? "Choose…" : names.joined(separator: ", ")).lineLimit(1)
            }
            .frame(height: CardLayout.control)
        }
    }
    private var one: Binding<String> { Binding(get: { picked.first ?? "" }, set: { picked = [$0] }) }
    private func binding(_ option: Card.Choice.Option) -> Binding<Bool> {
        Binding(get: { picked.contains(option.value) }, set: { on in
            let others = picked.filter { $0 != option.value }
            picked = on ? choice.options.map(\.value).filter { others.contains($0) || $0 == option.value } : others
        })
    }
    private func title(_ option: Card.Choice.Option) -> Text {
        option.detail.map { Text(option.text) + Text("  " + $0).foregroundStyle(.secondary) } ?? Text(option.text)
    }
}
