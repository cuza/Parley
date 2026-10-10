import AppKit
import Foundation
import SwiftProtobuf
import SwiftUI
import Testing
@testable import Parley

/// Inputs inside a message's card, as Google Chat draws and sends them: text fields (label, hint, several lines,
/// validation), every selection kind, date and time pickers, a row's switch, two real columns, actions that need inputs
/// filled, overflow menus, and cards that need more than Parley draws. Content-free shapes of what apps send.
struct CardFormTests {
    private static let send = Data(try! Dynamite_CardAction.with { $0.function = "f" }.serializedBytes() as [UInt8])
    private func text(_ string: String) -> Dynamite_FormattedText { .with { $0.segments = [.with { $0.run.text = string }] } }
    private func message(_ widgets: [Dynamite_CardWidget], configure: (inout Dynamite_Card) -> Void = { _ in }) -> Dynamite_Message {
        .with { m in
            m.id.messageID = "m1"; m.id.parentID.topicID.topicID = "m1"; m.creator.userID.id = "bot1"
            m.appAttachments = [.with { $0.attachmentID = "c1"; $0.card.sections = [.with { $0.widgets = widgets }]; configure(&$0.card) }]
        }
    }
    private func card(_ proto: Dynamite_Message) throws -> Card {
        try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:])?.attachments.first?.card)
    }
    private func items(_ widgets: [Dynamite_CardWidget]) throws -> [Card.Item] { try #require(try card(message(widgets)).sections.first) }
    private func gaps(_ proto: Dynamite_Message) -> [String] { MessageCoverage.gaps(proto, selfID: "me") }
    private func option(_ value: String, selected: Bool = false) -> Dynamite_SelectionItem {
        .with { $0.text = value.uppercased(); $0.value = value; $0.selected = selected }
    }

    // MARK: Text fields

    @Test func aTextFieldKeepsItsLabelHintAndRules() throws {
        let proto = message([.with { $0.textInput = .with { t in
            t.name = "q"; t.label = "L"; t.value = "v"; t.hintText = "H"; t.placeholderText = "P"; t.type = 1
            t.validation = .with { $0.characterLimit = 9; $0.inputType = 2 }
        } }])
        #expect(try card(proto).sections == [[.field(Card.Field(name: "q", label: "L", value: "v", hint: "H", placeholder: "P", multiline: true,
                                                                  limit: 9, kind: .integer))]])
        #expect(try card(proto).inputs == [Card.Input(name: "q", value: "v")])
        #expect(gaps(proto).isEmpty)
    }
    /// An empty text field goes too, as Google Chat sends every one.
    @Test func anEmptyTextFieldIsSent() throws {
        #expect(try card(message([.with { $0.textInput.name = "q" }])).inputs == [Card.Input(name: "q", value: "")])
    }

    // MARK: Choices

    @Test func everySelectionKindIsDrawnWithItsOptions() throws {
        let styles: [Card.Choice.Style] = [.checkbox, .radio, .switches, .menu, .multiple]
        for (type, style) in styles.enumerated() {
            let proto = message([.with { $0.selectionInput = .with { s in
                s.name = "c"; s.type = Int32(type); s.label = "L"; s.items = [option("a"), option("b", selected: true)]
                s.items[0].bottomText = "D"
            } }])
            #expect(try card(proto).sections == [[.choice(Card.Choice(name: "c", label: "L", style: style, options: [
                .init(text: "A", value: "a", selected: false, detail: "D"), .init(text: "B", value: "b", selected: true)]))]], "\(style)")
            #expect(gaps(proto).isEmpty, "\(style)")
        }
    }
    /// Several picked options go as several inputs under one name; none picked, nothing; a pop-up always sends the one
    /// it shows, as Google Chat's clients do.
    @Test func aChoiceSendsEachPickedValue() throws {
        func inputs(_ type: Int32, _ items: [Dynamite_SelectionItem]) throws -> [Card.Input] {
            try card(message([.with { $0.selectionInput = .with { $0.name = "c"; $0.type = type; $0.items = items } }])).inputs
        }
        #expect(try inputs(0, [option("a", selected: true), option("b"), option("c", selected: true)])
                == [Card.Input(name: "c", value: "a"), Card.Input(name: "c", value: "c")])
        #expect(try inputs(4, [option("a"), option("b")]) == [])
        #expect(try inputs(3, [option("a"), option("b")]) == [Card.Input(name: "c", value: "a")])
        #expect(try inputs(1, [option("a"), option("b", selected: true)]) == [Card.Input(name: "c", value: "b")])
        // An item without a value sends its text.
        #expect(try inputs(3, [.with { $0.text = "T"; $0.selected = true }]) == [Card.Input(name: "c", value: "T")])
    }

    // MARK: Dates

    @Test func aDatePickerSendsItsMomentAsGoogleChatDoes() throws {
        let proto = message([.with { $0.dateTimePicker = .with { $0.name = "d"; $0.label = "L"; $0.type = 2; $0.valueMsEpoch = 1_700_000_000_000 } }])
        #expect(try card(proto).sections == [[.date(Card.DateField(name: "d", label: "L", kind: .date, ms: 1_700_000_000_000))]])
        #expect(try card(proto).inputs == [Card.Input(name: "d", value: #"{"dateTimeMS":"1700000000000","hasDate":true,"hasTime":false,"type":2}"#)])
        #expect(gaps(proto).isEmpty)
        #expect(Card.dateValue(5, .time) == #"{"dateTimeMS":"5","hasDate":false,"hasTime":true,"type":3}"#)
        #expect(Card.dateValue(5, .dateAndTime) == #"{"dateTimeMS":"5","hasDate":true,"hasTime":true,"type":1}"#)
        // None chosen: nothing is sent; an unset type is date and time.
        let unset = message([.with { $0.dateTimePicker = .with { $0.name = "d" } }])
        #expect(try card(unset).sections == [[.date(Card.DateField(name: "d", label: nil, kind: .dateAndTime, ms: nil))]])
        #expect(try card(unset).inputs == [])
    }

    // MARK: Rows, columns

    /// A row's switch (in either field, as cards of different ages carry it) sends its value only while on.
    @Test func aRowsSwitchSendsItsValueWhileOn() throws {
        for field in [7, 22] {
            for on in [true, false] {
                let control = Dynamite_SwitchControl.with { $0.name = "s"; $0.value = "1"; $0.selected = on; $0.controlType = 1 }
                let proto = message([.with { $0.decoratedText = .with { d in d.text = text("T"); if field == 7 { d.switchControl = control } else { d.endSwitchControl = control } } }])
                #expect(try card(proto).sections == [[.row(icon: nil, round: false, label: nil, text: "T", formatting: [TextStyleRange(style: .nowrap, start: 0, length: 1)],
                                                           toggle: Card.Toggle(name: "s", value: "1", on: on, checkbox: false))]])
                #expect(try card(proto).inputs == (on ? [Card.Input(name: "s", value: "1")] : []))
                #expect(gaps(proto).isEmpty)
            }
        }
    }
    /// Columns holding more than buttons sit side by side, with every widget kind; their inputs go with the card's actions.
    @Test func columnsKeepEveryWidgetAndTheirInputs() throws {
        let proto = message([.with { $0.columns.columns = [
            .with { $0.widgets = [.with { $0.textParagraph.text = text("P") }, .with { $0.textInput.name = "t" }] },
            .with { $0.widgets = [.with { $0.selectionInput = .with { $0.name = "c"; $0.type = 0; $0.items = [option("a", selected: true)] } },
                                  .with { $0.dateTimePicker.name = "d" }, .with { $0.image.imageURL = "https://example.com/i.png" }] },
        ] }])
        let drawn = try card(proto)
        guard case .columns(let columns)? = drawn.sections.first?.first else { Issue.record("no columns"); return }
        #expect(columns.count == 2 && columns[0].count == 2 && columns[1].count == 3)
        #expect(columns[0] == [.text("P", []), .field(Card.Field(name: "t", label: "", value: ""))])
        #expect(drawn.inputs == [Card.Input(name: "t", value: ""), Card.Input(name: "c", value: "a")])
        #expect(gaps(proto).isEmpty)
    }
    @Test func columnsSitSideBySideOnlyWhenTheCardIsWide() {
        let columns = Card.Item.columns([[.divider, .divider], [.divider]])
        let line = CardLayout.height(.divider, width: 500)
        #expect(CardLayout.height(columns, width: 500) == 2 * line + CardLayout.gap)   // the taller column
        #expect(CardLayout.height(columns, width: 300) == 3 * line + 2 * CardLayout.gap)    // stacked
        #expect(CardLayout.columnWidth(500) == floor((500 - 2 * CardLayout.pad - CardLayout.columnGap) / 2))
    }

    // MARK: Actions

    /// An action that needs inputs filled names them; those inputs keep room to say "Required".
    @Test func anActionsRequiredInputsAreMarked() throws {
        let needs = Data(try Dynamite_CardAction.with { $0.function = "f"; $0.requiredWidgets = ["q"] }.serializedBytes() as [UInt8])
        let proto = message([.with { $0.textInput.name = "q" }, .with { $0.textInput.name = "r" },
                             .with { $0.buttons = [.with { $0.textButton = .with { $0.label = text("Go"); $0.onClick.action = needs } }] }])
        let items = try card(proto).sections.first ?? []
        #expect(items[0] == .field(Card.Field(name: "q", label: "", value: "", required: true)))
        #expect(items[1] == .field(Card.Field(name: "r", label: "", value: "")))
        guard case .links(let links) = items[2] else { Issue.record("no button"); return }
        #expect(links.first?.required == ["q"])
        #expect(CardLayout.caption(items[0]) && !CardLayout.caption(items[1]))
        let all = Data(try Dynamite_CardAction.with { $0.function = "f"; $0.allWidgetsAreRequired = true }.serializedBytes() as [UInt8])
        var every = proto; every.appAttachments[0].card.sections[0].widgets[2].buttons[0].textButton.onClick.action = all
        #expect(try card(every).sections.first?[1] == .field(Card.Field(name: "r", label: "", value: "", required: true)))
        #expect(gaps(proto).isEmpty)
    }
    /// An icon button whose click opens an overflow menu: each item opens its link or sends its action.
    @Test func anOverflowMenuListsItsItems() throws {
        let menu = Dynamite_OverflowMenu.with { $0.items = [
            .with { $0.text = "A"; $0.onClick.openLink.url = "https://example.com/a" },
            .with { $0.text = "B"; $0.onClick.action = Self.send },
            .with { $0.text = "C"; $0.onClick.action = Self.send; $0.disabled = true },
        ] }
        let proto = message([.with { $0.decoratedText = .with { d in d.text = text("T")
            d.button.imageButton = .with { $0.materialIcon.name = "more_vert"; $0.onClick.overflowMenu = menu } } }])
        guard case .row(_, _, _, _, _, _, let button?, _, _)? = try card(proto).sections.first?.first else { Issue.record("no button"); return }
        let chat = try #require(ChatLink.url(message: "space/s/m1/m1"))
        #expect(button.symbol == "ellipsis" && button.url == chat && button.action == nil)
        #expect(button.menu == [Card.MenuItem(title: "A", link: Card.Link(title: "A", url: URL(string: "https://example.com/a")!)),
                                Card.MenuItem(title: "B", link: Card.Link(title: "B", url: chat, action: Self.send)),
                                Card.MenuItem(title: "C", link: Card.Link(title: "C", url: chat, disabled: true))])
        #expect(gaps(proto).isEmpty)
    }
    /// A card that needs something Parley doesn't draw (here a grid) ends with a link to all of it in Google Chat.
    @Test func aCardNeedingMoreThanParleyDrawsSaysWhereToSeeIt() throws {
        let partial = message([.with { $0.textParagraph.text = text("x") }]) { $0.requiredFeatures = [2, 1000, 1015] }
        let last = try #require(try card(partial).sections.last)
        guard case .text(let note, let formatting, _)? = last.first else { Issue.record("no note"); return }
        #expect(note == "Open in Google Chat for the full card")
        #expect(formatting == [TextStyleRange(style: .link(ChatLink.url(message: "space/s/m1/m1")!), start: 0, length: 19)])
        #expect(gaps(partial).isEmpty)
        let whole = message([.with { $0.textParagraph.text = text("x") }]) { $0.requiredFeatures = [2, 1000, 1002, 1009, 1012, 1017, 1018, 1020, 2000] }
        #expect(try card(whole).sections == [[.text("x", [])]])
    }
    /// A row icon's alt text is what VoiceOver reads for it.
    @Test func aRowIconKeepsItsAltText() throws {
        let proto = message([.with { $0.decoratedText = .with { $0.text = text("T"); $0.icon.url = "https://example.com/i.png"; $0.icon.altText = "A"; $0.startIconAltText = "A" } }])
        guard case .row(_, _, _, _, _, _, _, _, let alt)? = try card(proto).sections.first?.first else { Issue.record("no row"); return }
        #expect(alt == "A")
        #expect(gaps(proto).isEmpty)
    }
}

extension AuthTests {
    /// Several values of one input go as several form inputs under its name, a date as Google Chat's JSON, in the card's order.
    @Test func clickCardSendsEveryValueOfEveryInput() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ClickCardResponse.with { $0.field1 = 1 })])
        let date = Card.dateValue(1_700_000_000_000, .dateAndTime)
        _ = try await backend.clickCard("dm/a/t1/h1", card: "c1", action: CardActionTests.reply, inputs: [
            Card.Input(name: "q", value: ""), Card.Input(name: "c", value: "a"), Card.Input(name: "c", value: "b"), Card.Input(name: "d", value: date)])
        let sent = try Dynamite_ClickCardRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(sent.formInputs == [.with { $0.name = "q"; $0.value = ""; $0.field4 = 1 }, .with { $0.name = "c"; $0.value = "a"; $0.field4 = 1 },
                                    .with { $0.name = "c"; $0.value = "b"; $0.field4 = 1 }, .with { $0.name = "d"; $0.value = date; $0.field4 = 1 }])
        // The bytes, field by field: 3 {1 name, 2 value, 4 1} per value.
        let first = try sent.formInputs[1].serializedBytes() as [UInt8]
        #expect(first == [0x0A, 0x01, 0x63, 0x12, 0x01, 0x61, 0x20, 0x01])
    }
}

/// Lists in message text: numbered ones count, nested ones step in, as Google Chat draws them.
struct MessageListTests {
    private func item(_ start: Int, _ length: Int, type: Int32, level: Int32) -> Dynamite_Annotation {
        .with { $0.type = .formatData; $0.startIndex = Int32(start); $0.length = Int32(length)
            $0.formatMetadata = .with { $0.formatType = .bulletedListItem; $0.list = .with { $0.listType = type; $0.nestingLevel = level } } }
    }
    @Test func numberedAndNestedListItemsAreKept() {
        // "a\nb\nc\nd\ne": a, b numbered; c nested under b, numbered from 1; d back at the top, 3; e a nested bullet.
        let text = "a\nb\nc\nd\ne"
        let (_, formatting) = DynamiteMapper.richText(text, [item(0, 2, type: 2, level: 0), item(2, 2, type: 2, level: 0), item(4, 2, type: 2, level: 1),
                                                             item(6, 2, type: 2, level: 0), item(8, 1, type: 1, level: 1)])
        #expect(formatting.map(\.style) == [.list(level: 0, number: 1), .list(level: 0, number: 2), .list(level: 1, number: 1),
                                            .list(level: 0, number: 3), .list(level: 1, number: nil)])
        // A plain top-level bullet stays the composer's own style.
        #expect(DynamiteMapper.richText("a", [item(0, 1, type: 1, level: 0)]).formatting.map(\.style) == [.listItem])
    }
    @Test func aListDrawsItsNumbersAndBullets() {
        let styled = MessageTextStyle.styled("a\nb", [TextStyleRange(style: .list(level: 0, number: 1), start: 0, length: 2),
                                                       TextStyleRange(style: .list(level: 1, number: nil), start: 2, length: 1)], own: false)
        #expect(styled.string == "1. a\n◦ b")
        let nested = styled.attribute(.paragraphStyle, at: styled.length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect(nested?.firstLineHeadIndent == 16)
    }
    @Test func aListIsSentBackAsItCame() {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .list(level: 1, number: 2), start: 0, length: 1)])
        #expect(sent.first?.formatMetadata.list.nestingLevel == 1 && sent.first?.formatMetadata.list.listType == 2)
    }
}

/// System lines and Gemini sources: an admin's membership change, a source's snippet.
struct AnnotationExtrasTests {
    @Test func anAdminsMembershipChangeIsNotNamed() {
        let proto = Dynamite_Message.with { m in
            m.creator.userID.id = "u1"
            m.annotations = [.with { $0.membershipChanged = .with { c in c.type = .added; c.initiator.id = "u1"; c.initiatorType = 2
                c.affectedMembers = [.with { $0.userID.id = "u2" }] } }]
        }
        let people = ["u1": Person(id: "u1", name: "Ana"), "u2": Person(id: "u2", name: "Ben")]
        #expect(DynamiteMapper.systemText(proto, in: "space/s", selfID: "me", people: people) == "An admin added Ben")
    }
    @Test func aSourcesSnippetIsItsDetail() {
        let source = Dynamite_ContextSource.with { $0.title = "T"; $0.url = "https://example.com"; $0.snippet.text = "S"; $0.footer.text = "F" }
        let annotation = Dynamite_Annotation.with { $0.contextSourceMetadata.sources = [source] }
        #expect(DynamiteMapper.sources([annotation]).first?.detail == "S")
        var footer = source; footer.clearSnippet()
        #expect(DynamiteMapper.sources([.with { $0.contextSourceMetadata.sources = [footer] }]).first?.detail == "F")
    }
}

/// A form card hosted as the timeline hosts it: every control inside the height `CardLayout` reserved for it.
@MainActor struct CardFormHostedTests {
    static let form = Card(sections: [[
        .field(Card.Field(name: "t", label: "Label", value: "", hint: "Hint")),
        .field(Card.Field(name: "m", label: "Label", value: "", multiline: true)),
        .choice(Card.Choice(name: "c", label: "Label", style: .checkbox, options: [.init(text: "A", value: "a", selected: true), .init(text: "B", value: "b", selected: false)])),
        .choice(Card.Choice(name: "r", label: nil, style: .radio, options: [.init(text: "A", value: "a", selected: true), .init(text: "B", value: "b", selected: false),
                                                                        .init(text: "C", value: "c", selected: false)])),
        .choice(Card.Choice(name: "s", label: nil, style: .switches, options: [.init(text: "A", value: "a", selected: false)])),
        .choice(Card.Choice(name: "p", label: "Label", style: .menu, options: [.init(text: "A", value: "a", selected: false)])),
        .choice(Card.Choice(name: "x", label: nil, style: .multiple, options: [.init(text: "A", value: "a", selected: false)])),
        .date(Card.DateField(name: "d", label: "Label", kind: .dateAndTime, ms: 1_700_000_000_000)),
        .row(icon: nil, round: false, label: nil, text: "Row", formatting: [], toggle: Card.Toggle(name: "o", value: "1", on: true, checkbox: false)),
        .columns([[.field(Card.Field(name: "l", label: "", value: ""))], [.choice(Card.Choice(name: "q", label: nil, style: .menu, options: [.init(text: "A", value: "a", selected: true)]))]]),
    ]])
    private func host(_ card: Card, width: CGFloat) -> (NSHostingView<CardView>, CGSize) {
        let size = CardLayout.size(card, maxWidth: width)
        let host = NSHostingView(rootView: CardView(card: card))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return (host, size)
    }
    private func controls(_ view: NSView) -> [NSView] {
        ((view is NSControl) ? [view] : []) + view.subviews.flatMap(controls)
    }
    @Test(arguments: [500.0, 320.0]) func everyControlFitsItsSlot(width: Double) throws {
        let (host, size) = host(Self.form, width: width)
        let found = controls(host)
        #expect(found.count >= 6, "\(found.map { type(of: $0) })")   // text fields, switches, the date: AppKit's own controls
        for control in found {
            let frame = control.convert(control.bounds, to: host)
            #expect(frame.minX >= CardLayout.pad - 0.5 && frame.maxX <= size.width - CardLayout.pad + 0.5, "\(type(of: control)) at \(frame) in \(size)")
            #expect(frame.minY >= -0.5 && frame.maxY <= size.height + 0.5, "\(type(of: control)) at \(frame) in \(size)")
        }
    }
    /// Each choice's control is no taller than the room `CardLayout` keeps for it.
    @Test func everyChoiceFitsItsRoom() {
        let options = ["a", "b", "c"].map { Card.Choice.Option(text: $0.uppercased(), value: $0, selected: false, detail: $0 == "b" ? "D" : nil) }
        for style in [Card.Choice.Style.checkbox, .radio, .switches, .menu, .multiple] {
            let choice = Card.Choice(name: "c", label: nil, style: style, options: options)
            let host = NSHostingView(rootView: CardChoice(choice: choice, picked: .constant(["b"])))
            #expect(host.fittingSize.height <= CardLayout.height(.choice(choice), width: 500) + 0.5, "\(style): \(host.fittingSize)")
            #expect(host.fittingSize.width <= 500 - 2 * CardLayout.pad, "\(style)")
        }
    }
    /// Columns sit side by side in a wide card, one under the other in a narrow one.
    @Test func columnsWrapInANarrowCard() throws {
        let card = Card(sections: [[.columns([[.field(Card.Field(name: "a", label: "", value: ""))], [.field(Card.Field(name: "b", label: "", value: ""))]])]])
        func fields(_ width: CGFloat) -> [CGRect] {
            let (host, _) = host(card, width: width)
            func all(_ view: NSView) -> [NSTextField] { ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return all(host).filter(\.isEditable).map { $0.convert($0.bounds, to: host) }.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        }
        let wide = fields(500), narrow = fields(320)
        #expect(wide.count == 2 && narrow.count == 2)
        #expect(abs(wide[0].midY - wide[1].midY) < 1 && wide[0].maxX < wide[1].minX)
        #expect(narrow[0].maxY <= narrow[1].minY + 0.5)
    }
}
