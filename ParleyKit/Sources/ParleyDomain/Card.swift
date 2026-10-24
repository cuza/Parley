import Foundation

/// An app's card, read-only, as Google Chat draws it under the message: sections of items.
public struct Card: Hashable, Codable, Sendable {
    public var sections: [[Item]]
    public enum Item: Hashable, Codable, Sendable {
        case text(String, [TextStyleRange], lines: Int? = nil)  // lines: cut to that many; nil: all
        /// A row with an optional icon (round: an avatar; `alt` says what it shows), a small label above, its text, and a
        /// button or a switch at its end.
        case row(
            icon: URL?, round: Bool, label: String?, text: String, formatting: [TextStyleRange], open: URL? = nil,
            button: Link? = nil,
            toggle: Toggle? = nil, alt: String? = nil)  // open: a click on the row opens it
        case links([Link])
        case image(URL, aspect: Double, click: Link? = nil, alt: String? = nil)  // aspect: width over height; click: what a click does
        case divider
        case field(Field)  // a text field; its value goes with the card's actions
        case choice(Choice)  // check boxes, radio buttons, switches, a pop-up menu or a multiple choice
        case date(DateField)  // a date, a time or both
        /// Two columns side by side, stacked when the card is narrow (`CardLayout.sideBySide`).
        case columns([[Item]])
        /// A collapsible section's toggle, last in it: the `hidden` items before it show only once expanded.
        case collapse(more: String, less: String, hidden: Int)
    }
    /// The items of `section` drawn: a collapsed section without what it hides.
    public static func shown(_ section: [Item], expanded: Bool) -> [Item] {
        guard !expanded, case .collapse(_, _, let hidden)? = section.last else { return section }
        var items = section
        items.removeSubrange(max(0, items.count - 1 - hidden)..<(items.count - 1))
        return items
    }
    /// What a card sends back with an action: one value of one of its inputs, by name. An input with several values
    /// (check boxes) sends one per value under the same name, as Google Chat does.
    public struct Input: Hashable, Codable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }
    /// A text field: its label above, its hint (or what's wrong) under it.
    public struct Field: Hashable, Codable, Sendable {
        public var name: String, label: String, value: String
        public var hint: String?, placeholder: String?
        public var multiline: Bool?
        public var limit: Int?  // characters at most
        public var kind: Kind?  // what it must hold; nil: any text
        public var required: Bool?  // an action needs it filled
        public init(
            name: String, label: String, value: String, hint: String? = nil, placeholder: String? = nil,
            multiline: Bool? = nil,
            limit: Int? = nil, kind: Kind? = nil, required: Bool? = nil
        ) {
            self.name = name
            self.label = label
            self.value = value
            self.hint = hint
            self.placeholder = placeholder
            self.multiline = multiline
            self.limit = limit
            self.kind = kind
            self.required = required
        }
        public enum Kind: String, Codable, Sendable { case integer, number, email }
    }
    /// A selection input, its options with what each sends.
    public struct Choice: Hashable, Codable, Sendable {
        public var name: String, label: String?, style: Style, options: [Option]
        public var limit: Int?  // a multiple choice's most picks
        public var required: Bool?
        public init(
            name: String, label: String? = nil, style: Style, options: [Option], limit: Int? = nil,
            required: Bool? = nil
        ) {
            self.name = name
            self.label = label
            self.style = style
            self.options = options
            self.limit = limit
            self.required = required
        }
        public enum Style: String, Codable, Sendable { case checkbox, radio, switches, menu, multiple }
        public struct Option: Hashable, Codable, Sendable {
            public var text: String
            public var value: String
            public var selected: Bool
            public var detail: String?
            public init(text: String, value: String, selected: Bool, detail: String? = nil) {
                self.text = text
                self.value = value
                self.selected = selected
                self.detail = detail
            }
        }
    }
    /// A date or time picker; `ms` is the chosen moment (nil: none), shown in the viewer's time zone.
    public struct DateField: Hashable, Codable, Sendable {
        public var name: String, label: String?, kind: Kind, ms: Int64?
        public var required: Bool?
        public init(name: String, label: String? = nil, kind: Kind, ms: Int64? = nil, required: Bool? = nil) {
            self.name = name
            self.label = label
            self.kind = kind
            self.ms = ms
            self.required = required
        }
        public enum Kind: Int, Codable, Sendable {
            case dateAndTime = 1
            case date = 2
            case time = 3
        }  // Google Chat's numbers
    }
    /// A switch or check box at a row's end: `value` goes with the card's actions while it is on.
    public struct Toggle: Hashable, Codable, Sendable {
        public var name: String
        public var value: String
        public var on: Bool
        public var checkbox: Bool
        public init(name: String, value: String, on: Bool, checkbox: Bool) {
            self.name = name
            self.value = value
            self.on = on
            self.checkbox = checkbox
        }
    }
    /// Every item, columns' too, in order.
    public var allItems: [Item] {
        func flat(_ items: [Item]) -> [Item] {
            items.flatMap { if case .columns(let columns) = $0 { [$0] + columns.flatMap(flat) } else { [$0] } }
        }
        return flat(sections.flatMap { $0 })
    }
    /// The card's inputs' values as they arrived, by name, in order (`CardView` keeps what is changed): a text field's
    /// even when empty, a choice's selected options, a switch only when on, a date when one is set.
    public var form: [(name: String, values: [String])] {
        allItems.compactMap { item in
            switch item {
            case .field(let field): (field.name, [field.value])
            case .choice(let choice):
                (
                    choice.name,
                    choice.style == .menu || choice.style == .radio
                        ? [(choice.options.first(where: \.selected) ?? choice.options.first)?.value].compactMap { $0 }  // a pop-up always shows one
                        : choice.options.filter(\.selected).map(\.value)
                )
            case .date(let date): (date.name, date.ms.map { [Self.dateValue($0, date.kind)] } ?? [])
            case .row(_, _, _, _, _, _, _, let toggle?, _): (toggle.name, toggle.on ? [toggle.value] : [])
            default: nil
            }
        }
    }
    /// What `form` sends: one input per value.
    var inputs: [Input] { form.flatMap { name, values in values.map { Input(name: name, value: $0) } } }
    /// A date's value as Google Chat's clients send it: a small JSON object.
    public static func dateValue(_ ms: Int64, _ kind: DateField.Kind) -> String {
        #"{"dateTimeMS":"\#(ms)","hasDate":\#(kind != .time),"hasTime":\#(kind != .date),"type":\#(kind.rawValue)}"#
    }
    public struct Link: Hashable, Codable, Sendable {
        public var title: String
        public var url: URL
        public var trailing: Bool?  // set at the row's end (a button in an end-aligned column)
        public var filled: Bool?  // a filled button; otherwise outlined, as Google Chat draws a card's buttons
        public var action: Data?  // an action Parley sends (`ChatBackend.clickCard`); `url` is then the fallback
        public var look: Look?  // tonal or borderless; nil: `filled` decides
        public var color: UInt32?  // a filled button's own colour, ARGB
        public var disabled: Bool?  // drawn greyed, does nothing
        public var symbol: String?  // an SF Symbol before the title (alone on an icon button, whose title is empty)
        public var icon: URL?  // the icon as a picture, when no symbol stands for it
        public var alt: String?  // what the button does, for the tooltip and VoiceOver
        public var menu: [MenuItem]?  // a click opens this menu instead
        public var required: [String]?  // inputs (by name) its action needs filled
        public var dialog: Bool?  // its action opens the app's dialog (`ChatBackend.dialog`) instead of acting in the card
        public init(
            title: String, url: URL, trailing: Bool? = nil, filled: Bool? = nil, action: Data? = nil, look: Look? = nil,
            color: UInt32? = nil, disabled: Bool? = nil, symbol: String? = nil, icon: URL? = nil, alt: String? = nil,
            menu: [MenuItem]? = nil, required: [String]? = nil, dialog: Bool? = nil
        ) {
            self.title = title
            self.url = url
            self.trailing = trailing
            self.filled = filled
            self.action = action
            self.look = look
            self.color = color
            self.disabled = disabled
            self.symbol = symbol
            self.icon = icon
            self.alt = alt
            self.menu = menu
            self.required = required
            self.dialog = dialog
        }
        public enum Look: String, Codable, Sendable { case tonal, borderless }
    }
    /// An overflow menu's item: its title, and what choosing it does.
    public struct MenuItem: Hashable, Codable, Sendable {
        public var title: String
        public var link: Link
        public init(title: String, link: Link) {
            self.title = title
            self.link = link
        }
    }
    /// The card's id in its message, which a click sends back (`click_card`); nil: none.
    public var id: String?
    /// The app's user id, which its dialogs' requests name; nil: not known.
    public var app: PersonID?
    /// Every button and click in the card, in order: rows' end buttons, button rows, pictures' clicks, menus' items.
    public var links: [Link] {
        allItems.flatMap { item -> [Link] in
            switch item {
            case .row(_, _, _, _, _, _, let button?, _, _): [button]
            case .links(let links): links
            case .image(_, _, let click?, _): [click]
            default: []
            }
        }.flatMap { [$0] + ($0.menu ?? []).map(\.link) }
    }
    /// Drawn without a box: the buttons an app puts under its message ("accessory widgets").
    public var bare: Bool?
    /// False: no line between its sections (the app draws its own dividers); nil: a line, as Google Chat draws by default.
    public var dividers: Bool?
    /// The app that made the card, shown under it as Google Chat does: "By <app>" and an App badge; nil: none.
    public var by: Attribution?
    public struct Attribution: Hashable, Codable, Sendable {
        public var name: String
        public var icon: URL?
        public init(name: String, icon: URL? = nil) {
            self.name = name
            self.icon = icon
        }
    }
    /// A button that hides the card in Parley only (an app suggestion's "Don't install"); nil: none.
    public var dismiss: String?
    public init(
        sections: [[Item]], id: String? = nil, app: PersonID? = nil, bare: Bool? = nil, dividers: Bool? = nil,
        by: Attribution? = nil,
        dismiss: String? = nil
    ) {
        self.sections = sections
        self.id = id
        self.app = app
        self.bare = bare
        self.dividers = dividers
        self.by = by
        self.dismiss = dismiss
    }
    /// Grey for a card's small print, such as "Only visible to you": readable on light and dark.
    public static let secondaryText: UInt32 = 0xFF80_868B
}
/// An app's dialog, as Google Chat shows it over the conversation: a title, its card, and the buttons fixed at its bottom.
public struct AppDialog: Hashable, Sendable {
    public var title: String?  // the card's header; nil: the app's name
    public var card: Card
    public var primary: Card.Link?  // the default button (Create, Submit)
    public var secondary: Card.Link?
    public init(title: String? = nil, card: Card, primary: Card.Link? = nil, secondary: Card.Link? = nil) {
        self.title = title
        self.card = card
        self.primary = primary
        self.secondary = secondary
    }
}
/// Where a dialog belongs and its app: the message it opened from (a card's, or a slash command's own message), or a
/// quick command, which has no message, by its id and conversation.
public struct DialogContext: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case message(MessageID)
        case command(Int64, in: ConversationID)
    }
    public var source: Source
    public var app: PersonID
    public init(message: MessageID, app: PersonID) {
        source = .message(message)
        self.app = app
    }
    public init(command: Int64, in conversation: ConversationID, app: PersonID) {
        source = .command(command, in: conversation)
        self.app = app
    }
    /// The message, or a quick command's conversation: what the dialog's links point at. Either kind, so plain text.
    public var anchor: String {
        switch source {
        case .message(let id): id.rawValue
        case .command(_, let conversation): conversation.rawValue
        }
    }
}
/// A dialog's requests: open it (from a card's button, or with no action for a slash command), press one of its
/// buttons, or close it.
public enum DialogStep: Sendable { case open, submit, cancel }
/// What an app answers.
public enum DialogAnswer: Hashable, Sendable {
    case show(AppDialog)  // the dialog, or its next step in the same sheet
    case close(String?)  // done, with the app's note for a moment ("Poll started.")
    case invalid(String)  // stays open, saying what's wrong (empty: the app gave no reason)
    case configure(URL)  // the app needs setting up first, on its page in the browser
}
