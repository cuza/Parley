import Foundation
import ParleyDomain

extension DynamiteMapper {
    /// An app that could preview a link in my message, offered to me alone, as Google Chat draws it under the message:
    /// "Only visible to you", the app, why, and Install, which opens the message in Google Chat where the install
    /// dialog lives. "Don't install" hides it in Parley only.
    /// Also an app that needs setting up (types 1–4 with a required action), as Google Chat's
    /// clients word it: "<app> requires authentication" with Sign in, "requires configuration" with Configure (both open
    /// the setup link), or "<app> not responding". The app is named as looked up (`cardAppIDs`), else "App".
    static func appCards(_ proto: Dynamite_Message, id: MessageID, people: [String: Person] = [:]) -> [Attachment] {
        let setups: [Attachment] = proto.botResponses.filter { (1...4).contains($0.type) && $0.hasRequiredAction }.map {
            response -> Attachment in
            let known = people[response.bot.userID.id].flatMap { $0.name == "Unknown" ? nil : $0 }
            let app = response.bot.name.isEmpty ? known?.name ?? "App" : response.bot.name
            let only = "Only visible to you"
            let icon =
                URL(string: response.bot.avatarURL).flatMap { $0.scheme == "https" ? $0 : nil } ?? known?.avatarURL
            let (title, button): (String, String?) =
                switch response.requiredAction {
                case 1: ("\(app) requires configuration", "Configure")
                case 2: ("\(app) requires authentication", "Sign in")
                default: ("\(app) not responding", nil)
                }
            // The message itself says "Only visible to you" when the server holds it for me alone (state 2).
            var items: [Card.Item] =
                (proto.messageState == 2
                    ? []
                    : [
                        .text(
                            only,
                            [
                                TextStyleRange(
                                    style: .color(Card.secondaryText), start: 0, length: (only as NSString).length)
                            ])
                    ])
                + [
                    .row(
                        icon: icon, round: false, label: nil, text: app,
                        formatting: [TextStyleRange(style: .bold, start: 0, length: (app as NSString).length)]),
                    .text(title, []),
                ]
            if let button, let url = URL(string: response.setupURL), url.scheme == "https" {
                items.append(.links([Card.Link(title: button, url: url)]))
            }
            return Attachment(name: app, kind: .card, card: Card(sections: [items]))
        }
        return suggestions(proto, id: id) + setups
    }
    private static func suggestions(_ proto: Dynamite_Message, id: MessageID) -> [Attachment] {
        proto.botResponses.filter { $0.type == appSuggestion && !$0.bot.name.isEmpty }.map { response in
            let app = response.bot.name
            let only = "Only visible to you"
            var top: [Card.Item] = [
                .text(
                    only,
                    [TextStyleRange(style: .color(Card.secondaryText), start: 0, length: (only as NSString).length)]),
                .row(
                    icon: URL(string: response.bot.avatarURL).flatMap { $0.scheme == "https" ? $0 : nil }, round: false,
                    label: nil,
                    text: app, formatting: [TextStyleRange(style: .bold, start: 0, length: (app as NSString).length)]),
                // ponytail: always the not-installed wording; Google Chat says "add <app> to this conversation" when I already have the app.
                .text("To interactively preview this link, install \(app) and add it to this conversation.", []),
            ]
            if let open = ChatLink.url(message: id) { top.append(.links([Card.Link(title: "Install", url: open)])) }
            return Attachment(name: app, kind: .card, card: Card(sections: [top], dismiss: "Don't install"))
        }
    }
    /// An app's cards as attachments drawn under the message: the header (with its picture), sections (collapsible ones
    /// end in their toggle), paragraphs and rows with their formatting, a row's end button, pictures, and buttons: one
    /// that opens a link opens it, one that sends an action to the app sends it (`click_card`, with the card's `id`),
    /// one that opens a dialog carries its action too, marked `dialog` (Parley opens the dialog, `ChatBackend.dialog`).
    /// The buttons an app puts under its message ("accessory_actions") are drawn bare; Ask Gemini's feedback row (icon
    /// buttons only) and a Meet call's card (its chip says the same) are left out.
    static func cards(_ proto: Dynamite_Message, id: MessageID? = nil, people: [String: Person] = [:]) -> [Attachment] {
        let chat = id.flatMap(ChatLink.url(message:))
        guard !isMeetCall(proto) else { return [] }
        return proto.appAttachments.compactMap { attachment -> Attachment? in
            guard attachment.hasCard, !isFeedbackRow(attachment) else { return nil }
            var sections = Self.sections(attachment.card, chat: chat)
            guard !sections.isEmpty else { return nil }
            // A card that needs what Parley doesn't draw says where to see all of it, as Google Chat's other clients do.
            if let chat, attachment.card.requiredFeatures.contains(where: { !supportedFeatures.contains($0) }) {
                let note = "Open in Google Chat for the full card"
                let open = "Open in Google Chat"
                sections.append([
                    .text(note, [TextStyleRange(style: .link(chat), start: 0, length: (open as NSString).length)])
                ])
            }
            let name =
                sections.lazy.flatMap { $0 }.compactMap { item -> String? in
                    if case .text(let text, _, _) = item {
                        text
                    } else if case .row(_, _, _, let text, _, _, _, _, _) = item {
                        text
                    } else {
                        nil
                    }
                }.first ?? "Card"
            // The app that made it, once looked up (see `cardAppIDs`).
            let by = people[attachment.app.userID.id].flatMap { $0.name == "Unknown" ? nil : $0 }.map {
                Card.Attribution(name: $0.name, icon: $0.avatarURL)
            }
            // The app its dialogs talk to: the card's own, else the app that sent the message.
            let app =
                attachment.app.userID.id.isEmpty
                ? (proto.creator.userID.type == .bot ? proto.creator.userID.id : "") : attachment.app.userID.id
            return Attachment(
                name: name, kind: .card,
                card: Card(
                    sections: sections, id: attachment.attachmentID.nilIfEmpty,
                    app: app.nilIfEmpty.map { PersonID($0) },
                    bare: attachment.attachmentID == accessoryActions ? true : nil,
                    dividers: attachment.card.sectionDividerStyle == 2 ? false : nil, by: by))
        }
    }
    /// An app's dialog as the sheet draws it: the header's title as the sheet's, the sections, and the fixed footer's
    /// buttons. Every action in it goes back as a submit (`DialogStep.submit`).
    static func dialog(_ card: Dynamite_Card, message: MessageID) -> AppDialog {
        let chat = ChatLink.url(message: message)
        var title = CardText()
        title.add(card.header.title)
        var sections = Self.sections(card, chat: chat, header: false)
        var subtitle = CardText()
        subtitle.add(card.header.subtitle)
        if let item = subtitle.item { sections.insert([item], at: 0) }
        func button(_ text: Dynamite_TextButton) -> Card.Link? { link(.with { $0.textButton = text }, chat: chat) }
        let footer = card.fixedFooter
        return AppDialog(
            title: title.trimmed.nilIfEmpty,
            card: Card(sections: sections, dividers: card.sectionDividerStyle == 2 ? false : nil),
            primary: footer.hasPrimaryButton ? button(footer.primaryButton) : nil,
            secondary: footer.hasSecondaryButton ? button(footer.secondaryButton) : nil)
    }
    /// A card's sections as drawn (with its header unless `header` is false), its required inputs marked.
    private static func sections(_ card: Dynamite_Card, chat: URL?, header: Bool = true) -> [[Card.Item]] {
        var sections: [[Card.Item]] = []
        if header, card.hasHeader {
            let top = card.header
            var title = CardText()
            title.add(top.title, bold: true)
            var subtitle = CardText()
            subtitle.add(top.subtitle)
            if let image = imageURL(top.imageURL) {  // the picture left of the title and subtitle, as web draws it
                var text = CardText()
                text.add(top.title, bold: true)
                text.newline()
                text.add(top.subtitle, over: [.color(Card.secondaryText)])
                sections.append([
                    .row(
                        icon: image, round: top.imageType == 2, label: nil, text: text.trimmed,
                        formatting: text.formatting)
                ])
            } else {
                sections.append([title.item, subtitle.item].compactMap { $0 })
            }
        }
        for section in card.sections {
            var items: [Card.Item] = []
            var boundary: Int?
            if !section.header.isEmpty {
                items.append(
                    .text(
                        section.header,
                        [TextStyleRange(style: .bold, start: 0, length: (section.header as NSString).length)]))
            } else if section.hasFormattedHeader {
                var header = CardText()
                header.add(section.formattedHeader)
                items += [header.item].compactMap { $0 }
            }
            for (index, widget) in section.widgets.enumerated() {
                if section.collapsible, index == Int(section.uncollapsibleWidgetsCount) { boundary = items.count }
                items += Self.items(widget, chat: chat)
            }
            // A collapsible section: what follows its first widgets shows once expanded, with the control's own words.
            if let boundary, boundary < items.count {
                func label(_ button: Dynamite_CardButton) -> String? {
                    var text = CardText()
                    text.add(button.textButton.label)
                    return text.trimmed.nilIfEmpty
                }
                // Only the expand words ("Advanced filters"): they stay once open, beside the turned chevron.
                let more = label(section.collapseControl.expandButton)
                items.append(
                    .collapse(
                        more: more ?? "Show more",
                        less: label(section.collapseControl.collapseButton) ?? more ?? "Show less",
                        hidden: items.count - boundary))
            }
            if !items.isEmpty { sections.append(items) }
        }
        return required(tidy(sections, lines: card.sectionDividerStyle != 2))
    }
    /// The card's dividers as Google Chat draws them: never two lines in a row (a divider next to a section's own line,
    /// or a section that is only a divider), nor one at the card's top or bottom. A collapsible section keeps its items,
    /// which its toggle counts.
    static func tidy(_ sections: [[Card.Item]], lines: Bool) -> [[Card.Item]] {
        var tidied: [[Card.Item]] = []
        var line = true  // the card's top counts as a line
        for section in sections {
            if lines, !tidied.isEmpty { line = true }
            if case .collapse? = section.last {
                tidied.append(section)
                line = false
                continue
            }
            var kept: [Card.Item] = []
            for item in section {
                if case .divider = item {
                    if line { continue }
                    line = true
                } else {
                    line = false
                }
                kept.append(item)
            }
            if lines, case .divider? = kept.last { kept.removeLast() }
            if !kept.isEmpty { tidied.append(kept) }
        }
        while case .divider? = tidied.last?.last {  // and none at the bottom
            tidied[tidied.count - 1].removeLast()
            if tidied.last?.isEmpty == true { tidied.removeLast() }
        }
        return tidied
    }
    /// What Google Chat's card features (`Card.required_features`) Parley draws: header, sections, paragraphs, icons, buttons,
    /// rows, images, text fields, date and time pickers, every selection kind, dividers, button lists, icon buttons,
    /// columns, row switches, code, lists, actions, links, overflow menus, Markdown. Not: footers (dialogs), grids,
    /// carousels, chips, autocompletion, navigation, Drive pickers.
    static let supportedFeatures: Set<Int32> = [
        1, 2, 1000, 1001, 1002, 1003, 1004, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013,
        1014, 1016, 1017, 1018, 1019, 1020, 1021, 1025, 1026, 2000, 2001, 2002, 2005, 3000,
    ]
    /// One widget's items, as Google Chat draws it (a column's widgets too).
    private static func items(_ widget: Dynamite_CardWidget, chat: URL?) -> [Card.Item] {
        var items: [Card.Item] = []
        if widget.hasImage, let url = URL(string: widget.image.imageURL), url.scheme == "https" {
            let click = link(onClick: widget.image.onClick, title: "", chat: chat)
            items.append(
                .image(
                    url, aspect: widget.image.aspectRatio > 0 ? widget.image.aspectRatio : 16.0 / 9, click: click,
                    alt: widget.image.altText.nilIfEmpty))
        }
        if widget.hasDivider { items.append(.divider) }
        if widget.hasTextInput { items.append(.field(field(widget.textInput))) }
        if widget.hasSelectionInput { items.append(.choice(choice(widget.selectionInput))) }
        if widget.hasDateTimePicker {
            let picker = widget.dateTimePicker
            items.append(
                .date(
                    Card.DateField(
                        name: picker.name, label: picker.label.nilIfEmpty,
                        kind: Card.DateField.Kind(rawValue: Int(picker.type)) ?? .dateAndTime,
                        ms: picker.valueMsEpoch > 0 ? picker.valueMsEpoch : nil)))
        }
        items += item(widget.textParagraph) + item(widget.decoratedText, chat: chat) + links(widget.buttons, chat: chat)
        return items + columns(widget.columns.columns, chat: chat)
    }
    /// Columns of buttons only share one row, the end column's at the end, as web lays them out; others sit side by side.
    private static func columns(_ columns: [Dynamite_CardColumn], chat: URL?) -> [Card.Item] {
        guard !columns.isEmpty else { return [] }
        if columns.allSatisfy({
            $0.widgets.allSatisfy { $0.buttons.count > 0 && !$0.hasTextParagraph && !$0.hasDecoratedText }
        }) {
            let row = columns.flatMap { column in
                links(column.widgets.flatMap(\.buttons), chat: chat).flatMap { item -> [Card.Link] in
                    guard case .links(let links) = item else { return [] }
                    return links.map {
                        var link = $0
                        if column.horizontalAlignment == 3 { link.trailing = true }
                        return link
                    }
                }
            }
            return row.isEmpty ? [] : [.links(row)]
        }
        let drawn = columns.prefix(2).map { column in  // two at most, as Google Chat allows
            column.widgets.flatMap { part in Self.items(widget(part), chat: chat) }
        }
        if let row = buttonRow(drawn) { return [row] }
        return drawn.contains(where: { !$0.isEmpty }) ? [.columns(drawn)] : []
    }
    /// A column's widget as a card widget, drawn the same way.
    private static func widget(_ part: Dynamite_CardColumnWidget) -> Dynamite_CardWidget {
        .with { copy in
            if part.hasDateTimePicker { copy.dateTimePicker = part.dateTimePicker }
            if part.hasImage { copy.image = part.image }
            if part.hasDecoratedText { copy.decoratedText = part.decoratedText }
            if part.hasSelectionInput { copy.selectionInput = part.selectionInput }
            if part.hasTextInput { copy.textInput = part.textInput }
            if part.hasTextParagraph { copy.textParagraph = part.textParagraph }
            copy.buttons = part.buttons
        }
    }
    /// Text beside a single button: a row with the button at its end, the text taking the rest, as web draws it.
    private static func buttonRow(_ drawn: [[Card.Item]]) -> Card.Item? {
        guard drawn.count == 2, drawn[0].count == 1, drawn[1].count == 1, case .links(let end) = drawn[1][0],
            end.count == 1
        else { return nil }
        switch drawn[0][0] {
        case .text(let text, let formatting, _):
            return .row(icon: nil, round: false, label: nil, text: text, formatting: formatting, button: end[0])
        case .row(let icon, let round, let label, let text, let formatting, let open, nil, nil, let alt):
            return .row(
                icon: icon, round: round, label: label, text: text, formatting: formatting, open: open, button: end[0],
                alt: alt)
        default: return nil
        }
    }
    private static func field(_ input: Dynamite_TextInput) -> Card.Field {
        let validation = input.validation
        let kind: Card.Field.Kind? =
            switch validation.inputType {
            case 2: .integer
            case 3: .number
            case 4: .email
            default: nil
            }
        return Card.Field(
            name: input.name, label: input.label, value: input.value, hint: input.hintText.nilIfEmpty,
            placeholder: input.placeholderText.nilIfEmpty, multiline: input.type == 1 ? true : nil,
            limit: validation.characterLimit > 0 ? Int(validation.characterLimit) : nil, kind: kind)
    }
    private static func choice(_ input: Dynamite_SelectionInput) -> Card.Choice {
        let style: Card.Choice.Style =
            switch input.type {
            case 0: .checkbox
            case 1: .radio
            case 2: .switches
            case 4: .multiple
            default: .menu
            }
        let options = input.items.map { item in
            Card.Choice.Option(
                text: item.text, value: item.value.isEmpty ? item.text : item.value, selected: item.selected,
                detail: item.bottomText.nilIfEmpty)
        }
        return Card.Choice(
            name: input.name, label: input.label.nilIfEmpty, style: style, options: options,
            limit: input.multiSelectMaxSelectedItems > 0 ? Int(input.multiSelectMaxSelectedItems) : nil)
    }
    /// The card with each input an action needs marked required, so it keeps room to say so.
    private static func required(_ sections: [[Card.Item]]) -> [[Card.Item]] {
        var names = Set<String>()
        var all = false
        func scan(_ link: Card.Link?) {
            guard let link else { return }
            for name in link.required ?? [] { if name == "*" { all = true } else { names.insert(name) } }
            link.menu?.forEach { scan($0.link) }
        }
        let card = Card(sections: sections)
        for item in card.allItems {
            switch item {
            case .links(let links): links.forEach(scan)
            case .row(_, _, _, _, _, _, let button, _, _): scan(button)
            case .image(_, _, let click, _): scan(click)
            default: break
            }
        }
        guard all || !names.isEmpty else { return sections }
        func mark(_ item: Card.Item) -> Card.Item {
            switch item {
            case .field(var field) where all || names.contains(field.name):
                field.required = true
                return .field(field)
            case .choice(var choice) where all || names.contains(choice.name):
                choice.required = true
                return .choice(choice)
            case .date(var date) where all || names.contains(date.name):
                date.required = true
                return .date(date)
            case .columns(let columns): return .columns(columns.map { $0.map(mark) })
            default: return item
            }
        }
        return sections.map { $0.map(mark) }
    }
    private static func item(_ widget: Dynamite_TextParagraph) -> [Card.Item] {
        guard widget.hasText else { return [] }
        var text = CardText()
        text.add(widget.text)
        guard case .text(let string, let formatting, _)? = text.item else { return [] }
        return [.text(string, formatting, lines: widget.maxLines > 0 ? Int(widget.maxLines) : nil)]
    }
    private static func item(_ widget: Dynamite_DecoratedText, chat: URL?) -> [Card.Item] {
        guard widget.hasText || widget.hasTopLabel else { return [] }
        // The row's on-click opens from anywhere on it, its text no link (web draws it plain); links in the text stay.
        var text = CardText()
        text.add(widget.text, over: widget.wrapText ? [] : [.nowrap])
        if widget.hasBottomLabel {
            text.newline()
            text.add(widget.bottomLabel, over: [.small, .color(Card.secondaryText)])
        }  // small grey print, as web
        var label = CardText()
        label.add(widget.topLabel)
        let iconURL = widget.icon.url.isEmpty ? widget.startIconURL : widget.icon.url
        let round = widget.icon.imageType == 2 || widget.startIconImageType == 2
        // The end button (or switch) sits in either of two fields, as cards of different ages carry it.
        let button = widget.hasEndButton ? widget.endButton : widget.hasButton ? widget.button : nil
        let control =
            widget.hasEndSwitchControl ? widget.endSwitchControl : widget.hasSwitchControl ? widget.switchControl : nil
        let toggle = control.map {
            Card.Toggle(name: $0.name, value: $0.value, on: $0.selected, checkbox: $0.controlType == 2)
        }
        let alt = [widget.icon.altText, widget.startIconAltText].first { !$0.isEmpty }
        return [
            .row(
                icon: URL(string: iconURL), round: round, label: label.text.nilIfEmpty,
                text: text.trimmed, formatting: text.formatting, open: openLink(widget.onClick),
                button: button.flatMap { link($0, chat: chat) },
                toggle: toggle, alt: alt)
        ]
    }
    /// The id of the buttons an app puts under its message (and of Gemini's feedback row).
    static let accessoryActions = "accessory_actions"
    /// Gemini's feedback row: icon buttons only, under the id "accessory_actions". An app's card with that id and a
    /// text button (a reminder's "Manage reminder") is not one.
    static func isFeedbackRow(_ attachment: Dynamite_AppAttachment) -> Bool {
        attachment.attachmentID == accessoryActions
            && !attachment.card.sections.contains {
                $0.widgets.contains { $0.buttons.contains(where: \.hasTextButton) }
            }
    }
    private static func links(_ buttons: [Dynamite_CardButton], chat: URL?) -> [Card.Item] {
        let links = buttons.compactMap { link($0, chat: chat) }
        return links.isEmpty ? [] : [.links(links)]
    }
    /// A card button as Google Chat draws it: its label (or only its icon), its look, greyed when disabled. One that
    /// sends an action to the app carries it (Parley sends it with `click_card`, or opens the app's dialog when it says
    /// so: `dialog`), with the message in Google Chat (`chat`) as its link.
    static func link(_ button: Dynamite_CardButton, chat: URL?) -> Card.Link? {
        if button.hasImageButton {
            let image = button.imageButton
            guard var link = link(onClick: image.onClick, title: "", chat: chat, disabled: image.disabled) else {
                return nil
            }
            link.symbol = symbol(image.materialIcon.name)
            link.icon = link.symbol == nil ? imageURL(image.iconURL) : nil
            link.alt = image.altText.nilIfEmpty
            return link.symbol == nil && link.icon == nil ? nil : link
        }
        let text = button.textButton
        var label = CardText()
        label.add(text.label)
        let symbol = symbol(text.materialIcon.name)
        let icon = symbol == nil ? imageURL(text.iconURL) : nil
        guard
            var link = link(
                onClick: text.onClick,
                title: label.text.isEmpty && symbol == nil && icon == nil ? "Open" : label.trimmed,
                chat: chat, disabled: text.disabled)
        else { return nil }
        // A colour makes a button filled in it, as Google Chat's public card docs say.
        link.filled = text.type == 2 || text.hasColor ? true : nil
        link.look = text.type == 3 && !text.hasColor ? .tonal : text.type == 4 && !text.hasColor ? .borderless : nil
        link.color = text.hasColor ? 0xFF00_0000 | text.color.light : nil
        link.symbol = symbol
        link.icon = icon
        link.alt = text.altText.nilIfEmpty
        return link
    }
    /// What a click does, as a button: open its link, or send its action (one that opens the app's dialog is marked). A
    /// disabled button with nowhere to go still draws, greyed.
    private static func link(onClick: Dynamite_CardOnClick, title: String, chat: URL?, disabled: Bool = false) -> Card
        .Link?
    {
        // An overflow menu: its items, each opening its link or sending its action.
        let menu = onClick.overflowMenu.items.compactMap { item -> Card.MenuItem? in
            guard !item.text.isEmpty,
                let link = link(onClick: item.onClick, title: item.text, chat: chat, disabled: item.disabled)
            else { return nil }
            return Card.MenuItem(title: item.text, link: link)
        }
        guard let url = openLink(onClick) ?? (onClick.hasAction || disabled || !menu.isEmpty ? chat : nil) else {
            return nil
        }
        let action =
            onClick.hasAction && openLink(onClick) == nil
            ? try? Dynamite_CardAction(serializedBytes: onClick.action) : nil
        let required = action.map { $0.allWidgetsAreRequired ? ["*"] : $0.requiredWidgets }.flatMap {
            $0.isEmpty ? nil : $0
        }
        return Card.Link(
            title: title, url: url, action: action != nil && !disabled ? onClick.action : nil,
            disabled: disabled ? true : nil,
            menu: menu.isEmpty ? nil : menu, required: required,
            dialog: action?.interaction == 1 && !disabled ? true : nil)
    }
    /// SF Symbols for the Material Symbols apps' buttons name; nil for others (their picture is loaded instead).
    static func symbol(_ material: String) -> String? {
        guard !material.isEmpty else { return nil }
        return [
            "more_vert": "ellipsis", "more_horiz": "ellipsis", "link": "link", "thumb_up": "hand.thumbsup",
            "thumb_up_alt": "hand.thumbsup",
            "thumb_down": "hand.thumbsdown", "thumb_down_alt": "hand.thumbsdown", "delete": "trash", "edit": "pencil",
            "add": "plus",
            "close": "xmark", "check": "checkmark", "done": "checkmark", "settings": "gearshape", "person": "person",
            "group": "person.2",
            "schedule": "clock", "event": "calendar", "mail": "envelope", "email": "envelope", "call": "phone",
            "videocam": "video",
            "search": "magnifyingglass", "info": "info.circle", "warning": "exclamationmark.triangle",
            "open_in_new": "arrow.up.right.square",
            "visibility": "eye", "visibility_off": "eye.slash", "refresh": "arrow.clockwise", "send": "paperplane",
            "star": "star",
            "share": "square.and.arrow.up", "help": "questionmark.circle", "how_to_vote": "checkmark.square",
            "poll": "chart.bar",
        ][material]
    }
    /// A card action's link: the original target, else Google's redirect. Nil for actions that need Google Chat.
    static func openLink(_ onClick: Dynamite_CardOnClick) -> URL? {
        guard onClick.hasOpenLink else { return nil }
        return URL(string: onClick.openLink.originalURL.isEmpty ? onClick.openLink.url : onClick.openLink.originalURL)
    }
    static func strippingTags(_ html: String) -> String {
        let breaks = html.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        let plain = breaks.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return plain.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
