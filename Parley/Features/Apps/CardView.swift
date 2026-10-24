import ParleyDomain
import SwiftUI

/// An app's card under its message, as Google Chat draws it: sections split by lines (a collapsible one with its
/// toggle), rows with an icon (round for a person), a small label, text and an end button, pictures, and buttons that
/// open a link or send their action. A bare card (the buttons an app puts under its message) has no box.
struct CardView: View {
    let card: Card
    var dismiss: () -> Void = {}
    var expanded = false  // a cut paragraph shows all of it ("Show more")
    var toggle: () -> Void = {}  // Show more / Show less
    /// Sends a button's action with the card's inputs (`ChatStore.clickCard`).
    var click: (Data, [Card.Input]) async -> Void = { _, _ in }
    /// A dialog's own buttons: the card then scrolls over them, and they send its inputs like the card's buttons.
    var footer: (primary: Card.Link?, secondary: Card.Link?)?
    var problem: String?  // in a dialog: what the app said is wrong, over its buttons
    @State private var values: [String: [String]] = [:]  // the card's inputs as changed here, by name (`Card.form` has the rest)
    @State private var dates: [String: Date] = [:]  // a date picker's moment, once chosen here
    @State private var missing: Set<String> = []  // required inputs left empty when an action was tried
    @State private var pending: Card.Link?  // a button whose action is on its way
    @Environment(\.openURL) private var openURL
    var body: some View {
        if let footer {
            sheet(primary: footer.primary, secondary: footer.secondary)
        } else {
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
                    box.frame(width: width, height: CardLayout.boxHeight(drawn, width: width, expanded: expanded))
                        .padding(DialogLayout.margin)
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).lineLimit(2).frame(
                    maxWidth: .infinity, alignment: .leading
                )
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
        var bold = AttributedString(name)
        bold.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("By ") + bold
    }
    /// The card as drawn: in a dialog, its text fields hold what was typed, so a multi-line one grows with it.
    private var drawn: Card {
        guard footer != nil, !values.isEmpty else { return card }
        func typed(_ item: Card.Item) -> Card.Item {
            switch item {
            case .field(var field):
                field.value = values[field.name]?.first ?? field.value
                return .field(field)
            case .columns(let columns): return .columns(columns.map { $0.map(typed) })
            default: return item
            }
        }
        var card = card
        card.sections = card.sections.map { $0.map(typed) }
        return card
    }
    private var box: some View {
        let card = drawn
        let inset = CardLayout.inset(card)
        let bare = card.bare == true
        let room = CardLayout.sectionRoom(card)
        let hugs = CardLayout.hugs(card)
        return GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 {  // a line between sections, unless the card draws its own, with room round it
                        if card.dividers == false {
                            Color.clear.frame(height: 2 * room)
                        } else {
                            Divider().padding(.vertical, room)
                        }
                    }
                    VStack(alignment: .leading, spacing: CardLayout.gap) {
                        ForEach(Array(Card.shown(section, expanded: expanded).enumerated()), id: \.offset) { _, item in
                            // Each item in a slot of the card's current width, leading: never centred, so content
                            // sized for an older, wider card can't push in from the left.
                            itemView(item, width: geometry.size.width - 2 * inset)
                                .frame(
                                    width: geometry.size.width - 2 * inset,
                                    height: CardLayout.height(
                                        item, width: geometry.size.width + 2 * (CardLayout.pad - inset),
                                        expanded: expanded, hugs: hugs), alignment: .topLeading)
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
            if let shown = CardLayout.cut(text, formatting, lines: lines, width: width) {  // cut: "…", and Show more under it
                VStack(alignment: .leading, spacing: CardLayout.gap) {
                    NativeMessageText(
                        text: expanded ? text : shown, formatting: formatting, own: false,
                        lines: expanded ? 0 : lines ?? 0, maxWidth: width)
                    Button(expanded ? "Show less" : "Show more", action: toggle).buttonStyle(.link).frame(
                        height: CardLayout.more)
                }
                .frame(width: width, alignment: .leading)
            } else {
                NativeMessageText(text: text, formatting: formatting, own: false, lines: lines ?? 0, maxWidth: width)
                    .frame(width: width, alignment: .leading)
            }
        case .row:
            rowView(item, width: width)
        case .links(let links):
            HStack(spacing: 8) {
                if let title = card.dismiss { Button(title, action: dismiss).buttonStyle(CardButtonStyle(link: nil)) }
                ForEach(links.filter { $0.trailing != true }, id: \.self, content: button)
                Spacer(minLength: 0)
                ForEach(links.filter { $0.trailing == true }, id: \.self, content: button)
            }
            .frame(width: width)
        case .image(let url, let aspect, let click, let alt):
            imageView(url, aspect: aspect, click: click, alt: alt, width: width)
        case .divider:
            Divider().frame(width: width).padding(.vertical, CardLayout.dividerPad)
        case .field(let field):
            fieldView(field, item, width: width)
        case .choice(let choice):
            input(
                label: choice.label, caption: CardLayout.caption(item),
                problem: missing.contains(choice.name) ? "Required" : nil, hint: nil, width: width
            ) {
                CardChoice(
                    choice: choice,
                    picked: Binding(
                        get: { values[choice.name] ?? card.form.first { $0.name == choice.name }?.values ?? [] },
                        set: {
                            values[choice.name] = $0
                            missing.remove(choice.name)
                        }))
            }
        case .date(let date):
            input(
                label: date.label, caption: CardLayout.caption(item),
                problem: missing.contains(date.name) ? "Required" : nil, hint: nil, width: width
            ) {
                dateView(date)
            }
        case .columns(let columns):
            columnsView(columns, width: width)
        case .collapse(let more, let less, _):  // a collapsible section's toggle: a disclosure chevron, as Google Chat draws it
            collapseView(more: more, less: less)
        }
    }
}

extension CardView {
    /// A row: its icon, a small label over its text, and an end button or switch.
    @ViewBuilder private func rowView(_ item: Card.Item, width: CGFloat) -> some View {
        if case .row(let icon, let round, let label, let text, let formatting, let open, let end, let toggle, let alt) =
            item
        {
            HStack(alignment: .top, spacing: CardLayout.iconGap) {
                if let icon { CardIcon(url: icon, round: round).accessibilityLabel(alt ?? "") }
                VStack(alignment: .leading, spacing: CardLayout.labelGap) {
                    if let label {
                        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(
                            height: CardLayout.labelHeight)
                    }
                    NativeMessageText(
                        text: text, formatting: formatting, own: false,
                        maxWidth: CardLayout.textWidth(
                            width + 2 * CardLayout.pad, icon: icon != nil, button: end, toggle: toggle)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)  // the proposed width, cut with "…" when it doesn't wrap
                }
                .overlay {  // the row's on-click: anywhere on it (but its button) opens it
                    if let open {
                        Link(destination: open) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).help(
                            open.absoluteString)
                    }
                }
                if let end {  // the end button, centred on the row, as web draws a poll's Vote
                    button(end).frame(
                        width: CardLayout.buttonWidth(end),
                        height: CardLayout.height(item, width: width + 2 * CardLayout.pad))
                } else if let toggle {  // a switch (or check box) at the row's end: its value goes with the card's actions while on
                    Toggle(
                        isOn: Binding(
                            get: { (values[toggle.name] ?? (toggle.on ? [toggle.value] : [])).isEmpty == false },
                            set: { values[toggle.name] = $0 ? [toggle.value] : [] })
                    ) { Text(text) }
                    .labelsHidden().toggleStyle(checkbox: toggle.checkbox).controlSize(.small)
                    .frame(
                        width: CardLayout.toggleWidth(toggle),
                        height: CardLayout.height(item, width: width + 2 * CardLayout.pad))
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }
    /// A picture; a click opens its link or sends its action.
    private func imageView(_ url: URL, aspect: Double, click: Card.Link?, alt: String?, width: CGFloat) -> some View {
        CardImage(url: url, alt: alt).frame(
            width: CardLayout.imageSize(url, aspect: aspect, slot: width, hugs: CardLayout.hugs(drawn)).width
        )
        .overlay {  // a click opens its link or sends its action
            if let click {
                if let action = click.action {
                    Button {
                        send(action, from: click)
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    Link(destination: click.url) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).help(
                        click.url.absoluteString)
                }
            }
        }
    }
    /// A text field, one line or growing with what's typed.
    private func fieldView(_ field: Card.Field, _ item: Card.Item, width: CGFloat) -> some View {
        input(
            label: field.label.isEmpty ? nil : field.label, caption: CardLayout.caption(item),
            problem: problem(field), hint: field.hint, width: width
        ) {
            let text = Binding(
                get: { values[field.name]?.first ?? field.value },
                set: {
                    values[field.name] = [$0]
                    missing.remove(field.name)
                })
            if field.multiline == true {  // one line high, growing with what's typed
                TextField(field.placeholder ?? "", text: text, axis: .vertical).lineLimit(
                    1...CardLayout.lines(field, width: width)
                )
                .modifier(CardFieldStyle(height: CardLayout.fieldHeight(field, width: width)))
            } else {
                TextField(field.placeholder ?? "", text: text).modifier(
                    CardFieldStyle(height: CardLayout.fieldControl))
            }
        }
    }
    /// Columns side by side, or one over the other when the card is narrow.
    @ViewBuilder private func columnsView(_ columns: [[Card.Item]], width: CGFloat) -> some View {
        let side = CardLayout.sideBySide(width + 2 * CardLayout.pad)
        let inner = CardLayout.columnWidth(width + 2 * CardLayout.pad)
        let layout =
            side
            ? AnyLayout(HStackLayout(alignment: .top, spacing: CardLayout.columnGap))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: CardLayout.gap))
        layout {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: CardLayout.gap) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, part in
                        AnyView(itemView(part, width: inner)).frame(
                            width: inner, height: CardLayout.height(part, width: inner + 2 * CardLayout.pad),
                            alignment: .topLeading)
                    }
                }
                .frame(width: inner, alignment: .topLeading)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
    private func collapseView(more: String, less: String) -> some View {
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

extension CardView {
    /// The card's inputs as they stand, in order: what was changed here, else what arrived.
    private var form: [(name: String, values: [String])] { card.form.map { ($0.name, values[$0.name] ?? $0.values) } }
    /// Sends `action` with the card's inputs; the answer replaces the message. Not while an input the action needs is
    /// empty or a text field holds what it can't: those say so under them, as Google Chat does.
    private func send(_ action: Data, from link: Card.Link) {
        let form = form
        let inputs = card.allItems.compactMap { item -> String? in  // what can be required: not a row's switch, which may be off
            switch item {
            case .field(let field): field.name
            case .choice(let choice): choice.name
            case .date(let date): date.name
            default: nil
            }
        }
        let needed = link.required == ["*"] ? Set(inputs) : Set(link.required ?? [])
        missing = Set(
            form.filter {
                needed.contains($0.name) && $0.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            }.map(\.name))
        let fields = card.allItems.compactMap { if case .field(let field) = $0 { field } else { nil } }
        guard missing.isEmpty, !fields.contains(where: { problem($0) != nil }) else { return }
        let sent = form.flatMap { name, values in values.map { Card.Input(name: name, value: $0) } }
        pending = link
        // A dialog keeps what was typed (the app may say what's wrong with it); its next step is a new card.
        Task {
            await click(action, sent)
            pending = nil
            if footer == nil {
                values = [:]
                dates = [:]
            }
        }
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
    private func input(
        label: String?, caption: Bool, problem: String?, hint: String?, width: CGFloat,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: CardLayout.labelGap) {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(
                    height: CardLayout.labelHeight)
            }
            control()
            if caption {
                Text(problem ?? hint ?? "").font(.caption).foregroundStyle(problem == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .frame(height: CardLayout.labelHeight)
            }
        }
        .frame(width: width, alignment: .leading)
    }
    /// A date, a time or both, in the viewer's time zone; one not chosen yet offers to set it.
    @ViewBuilder private func dateView(_ date: Card.DateField) -> some View {
        let initial = date.ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if let shown = dates[date.name] ?? initial {
            let components: DatePickerComponents =
                switch date.kind {
                case .date: .date
                case .time: .hourAndMinute
                case .dateAndTime: [.date, .hourAndMinute]
                }
            DatePicker(
                "", selection: Binding(get: { shown }, set: { pick($0, for: date) }), displayedComponents: components
            )
            .datePickerStyle(.field).labelsHidden().frame(height: CardLayout.control)
        } else {
            Button(date.kind == .time ? "Set a time" : "Set a date") { pick(.now, for: date) }.buttonStyle(.link).frame(
                height: CardLayout.control)
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
        let style = CardButtonStyle(link: link)
        let help = link.alt ?? (link.action == nil ? link.url.absoluteString : link.title)
        if let menu = link.menu, link.disabled != true {  // an overflow menu: its items, each doing its own thing
            Menu {
                ForEach(menu, id: \.self) { item in
                    Button(item.title) { run(item.link) }.disabled(item.link.disabled == true)
                }
            } label: {
                label(link)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(pending != nil).help(help).accessibilityLabel(
                link.alt ?? link.title)
        } else if link.disabled == true {  // greyed, and nothing happens
            Button {
            } label: {
                label(link)
            }.buttonStyle(style).disabled(true).help(help).accessibilityLabel(link.alt ?? link.title)
        } else if let action = link.action {  // sent from here: the card's inputs go with it, and the answer replaces the message
            Button {
                send(action, from: link)
            } label: {
                if pending == link { ProgressView().controlSize(.small) } else { label(link) }
            }
            .buttonStyle(style).disabled(pending != nil).help(help).accessibilityLabel(link.alt ?? link.title)
        } else {
            Link(destination: link.url) { label(link) }.buttonStyle(style).help(help).accessibilityLabel(
                link.alt ?? link.title)
        }
    }
    /// The icon (a symbol, else its picture) and the title.
    private func label(_ link: Card.Link) -> some View {
        HStack(spacing: CardLayout.buttonIconGap) {
            if let symbol = link.symbol {
                Image(systemName: symbol).frame(width: CardLayout.buttonIcon)
            } else if let icon = link.icon {
                CardIcon(url: icon, round: false, size: CardLayout.buttonIcon, template: true)
            }
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
        let iconOnly = link?.title.isEmpty == true
        let bordered = !filled && link?.look == nil && !iconOnly
        return configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(filled ? Color.white : iconOnly ? Color.secondary : Color.accentColor)
            .padding(.horizontal, iconOnly ? 0 : 12).frame(minWidth: iconOnly ? CardLayout.buttons : nil).frame(
                height: CardLayout.buttons - 2
            )
            .background(
                filled ? fill : link?.look == .tonal ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule()
            )
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
            if let image {
                Image(nsImage: image).renderingMode(template ? .template : .original).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(template ? 0 : 0.15)
            }
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
                if image.animated {
                    AnimatedImage(image: image)
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(alt ?? "Picture")
        .task(id: url) {
            image = await RemoteImage.image(url, px: 0)
            if let image { CardLayout.noteNatural(url, image.size) }
        }
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

extension View {
    /// A check box or a switch.
    @ViewBuilder fileprivate func toggleStyle(checkbox: Bool) -> some View {
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
                        .toggleStyle(checkbox: choice.style == .checkbox).controlSize(.small).frame(
                            height: CardLayout.option)
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
        Binding(
            get: { picked.contains(option.value) },
            set: { on in
                let others = picked.filter { $0 != option.value }
                picked = on ? choice.options.map(\.value).filter { others.contains($0) || $0 == option.value } : others
            })
    }
    private func title(_ option: Card.Choice.Option) -> Text {
        option.detail.map { Text(option.text) + Text("  " + $0).foregroundStyle(.secondary) } ?? Text(option.text)
    }
}
