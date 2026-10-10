import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Message cards drawn as Google Chat draws them: private messages, a row's end button (a poll's Vote), bold and HTML
/// card text, header pictures, collapsible sections, buttons of every look, pictures that animate and open, and the
/// buttons an app puts under its message. Content-free shapes of what apps send.
struct CardEngineTests {
    private func text(_ string: String, weight: Int32 = 0) -> Dynamite_FormattedText {
        .with { $0.segments = [.with { $0.run = .with { r in r.text = string; r.weight = weight } }] }
    }
    private static let vote = Data(try! Dynamite_CardAction.with { $0.function = "vote" }.serializedBytes() as [UInt8])
    private static let dialog = Data(try! Dynamite_CardAction.with { $0.function = "f"; $0.interaction = 1 }.serializedBytes() as [UInt8])
    private func message(_ widgets: [Dynamite_CardWidget] = [], body: String = "", configure: (inout Dynamite_Message) -> Void = { _ in }) -> Dynamite_Message {
        .with { m in
            m.id.messageID = "m1"; m.id.parentID.topicID.topicID = "m1"; m.textBody = body; m.creator.userID.id = "bot1"
            if !widgets.isEmpty { m.appAttachments = [.with { $0.attachmentID = "c1"; $0.card.sections = [.with { $0.widgets = widgets }] }] }
            configure(&m)
        }
    }
    private func mapped(_ proto: Dynamite_Message) throws -> Parley.Message {
        try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:]))
    }
    private func card(_ proto: Dynamite_Message) throws -> Card { try #require(try mapped(proto).attachments.first?.card) }
    private func gaps(_ proto: Dynamite_Message) -> [String] { MessageCoverage.gaps(proto, selfID: "me") }
    private var chat: URL { ChatLink.url(message: "space/s/m1/m1")! }

    // MARK: Message level

    @Test func aMessageOnlyIShowsSaysSo() throws {
        let held = message(body: "/command") { $0.messageState = 2; $0.botResponses = [.with { $0.type = 5 }] }   // a slash command's own message
        #expect(try mapped(held).via == "Only visible to you")
        #expect(try mapped(held).text == "/command")
        #expect(gaps(held).isEmpty)
        #expect(try mapped(message(body: "hi") { $0.messageState = 1 }).via == nil)
    }
    @Test func anAppsNameCarriesAnAppBadge() throws {
        let app = message(body: "hi") { $0.creator.userID.type = .bot }
        #expect(try mapped(app).via == "App")
        #expect(try mapped(message(body: "hi") { $0.creator.userID.type = .bot; $0.messageState = 2 }).via == "App · Only visible to you")
    }
    /// An app that needs configuring before it can answer, with no text: Google Chat's wording and its Configure button.
    @Test func setupRequiredWithoutTextSaysWhatTheAppNeeds() throws {
        let proto = message { m in
            m.messageState = 2; m.creator.userID.type = .bot
            m.botResponses = [.with { $0.type = 2; $0.requiredAction = 1; $0.setupURL = "https://example.com/setup"; $0.bot.name = "Board" }]
        }
        let shown = try mapped(proto)
        #expect(shown.text.isEmpty && shown.via == "App · Only visible to you")
        let items = try #require(shown.attachments.first?.card?.sections.first)
        #expect(items.contains(.text("Board requires configuration", [])))
        #expect(items.contains(.links([Card.Link(title: "Configure", url: URL(string: "https://example.com/setup")!)])))
        #expect(!items.contains { if case .text("Only visible to you", _, _) = $0 { true } else { false } })   // the message says it
        #expect(gaps(proto).isEmpty)
    }

    // MARK: Rows, buttons

    /// A poll option: its text, its votes, and Vote at the row's end, which sends the action with the card's id.
    @Test func aDecoratedTextsEndButtonIsDrawnAndSends() throws {
        for field in [6, 21] {
            let button = Dynamite_CardButton.with { $0.textButton = .with { $0.label = text("Vote", weight: 2); $0.onClick.action = Self.vote; $0.type = 1; $0.altText = "Vote: A" } }
            let row = Dynamite_DecoratedText.with { $0.text = text("A"); $0.wrapText = true; if field == 6 { $0.button = button } else { $0.endButton = button } }
            let proto = message([.with { $0.decoratedText = row }])
            let drawn = try card(proto)
            #expect(drawn.id == "c1")
            #expect(drawn.sections == [[.row(icon: nil, round: false, label: nil, text: "A", formatting: [], button:
                Card.Link(title: "Vote", url: chat, action: Self.vote, alt: "Vote: A"))]])
            #expect(gaps(proto).isEmpty, "\(field)")
        }
    }
    @Test func buttonsKeepTheirLookAndADisabledOneDoesNothing() throws {
        func button(_ configure: (inout Dynamite_TextButton) -> Void) -> Dynamite_CardButton {
            .with { b in b.textButton = .with { $0.label = text("B"); $0.onClick.action = Self.vote; configure(&$0) } }
        }
        let proto = message([.with { $0.buttons = [
            button { $0.type = 3 }, button { $0.type = 4 }, button { $0.color.light = 0x1A73E8 },
            button { $0.disabled = true; $0.onClick = Dynamite_CardOnClick() },   // "Awaiting votes": nowhere to go
            button { $0.materialIcon.name = "visibility"; $0.iconURL = "https://example.com/eye.svg" },
            button { $0.materialIcon.name = "unknown_icon"; $0.iconURL = "https://example.com/i.svg" },
            .with { $0.imageButton = .with { $0.materialIcon.name = "more_vert"; $0.altText = "More"; $0.onClick.openLink.url = "https://example.com" } },
        ] }])
        guard case .links(let links)? = try card(proto).sections.first?.first else { Issue.record("no buttons"); return }
        #expect(links.map(\.look) == [.tonal, .borderless, nil, nil, nil, nil, nil])
        #expect(links[2].filled == true && links[2].color == 0xFF1A73E8)
        #expect(links[3].disabled == true && links[3].action == nil && links[3].title == "B")
        #expect(links[4].symbol == "eye" && links[4].icon == nil)
        #expect(links[5].symbol == nil && links[5].icon == URL(string: "https://example.com/i.svg"))
        #expect(links[6] == Card.Link(title: "", url: URL(string: "https://example.com")!, symbol: "ellipsis", alt: "More"))
        #expect(gaps(proto).isEmpty)
    }

    // MARK: Text

    @Test func boldRunsAndHTMLOnlyTextKeepTheirFormatting() throws {
        let bold = message([.with { $0.textParagraph.text = text("Q", weight: 3) }])
        #expect(try card(bold).sections == [[.text("Q", [TextStyleRange(style: .bold, start: 0, length: 1)])]])
        #expect(gaps(bold).isEmpty)
        let html = message([.with { $0.textParagraph.text.html = "<b>Q</b><br><i>a &amp; b</i> <font color=\"#ff0000\">r</font><ul><li>x</li><li>y</li></ul><a href=\"https://example.com\">l</a>" }])
        guard case .text(let string, let formatting, _)? = try card(html).sections.first?.first else { Issue.record("no text"); return }
        #expect(string == "Q\na & b r\n• x\n• y\nl")
        #expect(formatting.contains(TextStyleRange(style: .bold, start: 0, length: 1)))
        #expect(formatting.contains(TextStyleRange(style: .italic, start: 2, length: 5)))
        #expect(formatting.contains(TextStyleRange(style: .color(0xFFFF0000), start: 8, length: 1)))
        #expect(formatting.contains(TextStyleRange(style: .link(URL(string: "https://example.com")!), start: 18, length: 1)))
        #expect(gaps(html).isEmpty)
    }
    @Test func aFormattedSectionHeaderIsDrawn() throws {
        let proto = message { $0.appAttachments = [.with { $0.card.sections = [.with { $0.formattedHeader = text("H", weight: 3)
            $0.widgets = [.with { $0.textParagraph.text = text("x") }] }] }] }
        #expect(try card(proto).sections == [[.text("H", [TextStyleRange(style: .bold, start: 0, length: 1)]), .text("x", [])]])
        #expect(gaps(proto).isEmpty)
    }
    @Test func aHeaderWithAPictureIsARow() throws {
        let proto = message { $0.appAttachments = [.with { $0.card.header = .with { h in h.title = text("T"); h.subtitle = text("S")
            h.imageURL = "https://example.com/p.png"; h.imageType = 2; h.imageAltText = "" }
            $0.card.sections = [.with { $0.widgets = [.with { $0.divider = .init() }] }] }] }
        #expect(try card(proto).sections.first == [.row(icon: URL(string: "https://example.com/p.png"), round: true, label: nil, text: "T\nS",
            formatting: [TextStyleRange(style: .bold, start: 0, length: 1), TextStyleRange(style: .color(Card.secondaryText), start: 2, length: 1)])])
        #expect(gaps(proto).isEmpty)
    }

    // MARK: Sections

    /// A poll's voters: the first widget shows, the rest behind the section's own "Show"/"Hide" words.
    @Test func aCollapsibleSectionHidesAllButItsFirstWidgets() throws {
        let control = Dynamite_CollapseControl.with { $0.expandButton.textButton.label = text("Show V"); $0.collapseButton.textButton.label = text("Hide V") }
        let proto = message { $0.appAttachments = [.with { $0.card.sections = [.with { s in
            s.collapsible = true; s.uncollapsibleWidgetsCount = 1; s.collapseControl = control
            s.widgets = ["a", "b", "c"].map { name in .with { $0.textParagraph.text = text(name) } }
        }] }] }
        let section = try #require(try card(proto).sections.first)
        #expect(section == [.text("a", []), .text("b", []), .text("c", []), .collapse(more: "Show V", less: "Hide V", hidden: 2)])
        #expect(Card.shown(section, expanded: false) == [.text("a", []), .collapse(more: "Show V", less: "Hide V", hidden: 2)])
        #expect(Card.shown(section, expanded: true) == section)
        #expect(gaps(proto).isEmpty)
        // Without the control's words, Google Chat's own.
        var plain = proto; plain.appAttachments[0].card.sections[0].clearCollapseControl()
        #expect(try card(plain).sections.first?.last == .collapse(more: "Show more", less: "Show less", hidden: 2))
    }
    /// The buttons an app puts under its message (a poll's "End voting") are drawn bare, without a card's box.
    @Test func accessoryButtonsAreBare() throws {
        let proto = message(body: "hi") { $0.appAttachments = [.with { $0.attachmentID = "accessory_actions"
            $0.card.sections = [.with { $0.widgets = [.with { $0.buttons = [.with { $0.textButton = .with { $0.label = text("End"); $0.onClick.action = Self.vote } }] }] }] }] }
        let drawn = try card(proto)
        #expect(drawn.bare == true && drawn.id == "accessory_actions")
    }

    // MARK: Pictures

    @Test func aPictureOpensItsLinkOrSendsItsAction() throws {
        let linked = message([.with { $0.image = .with { $0.imageURL = "https://example.com/a.gif"; $0.altText = "A"
            $0.onClick.openLink = .with { $0.url = "https://www.google.com/url?q=x"; $0.originalURL = "https://example.com/t" } } }])
        #expect(try card(linked).sections == [[.image(URL(string: "https://example.com/a.gif")!, aspect: 16.0 / 9,
            click: Card.Link(title: "", url: URL(string: "https://example.com/t")!), alt: "A")]])
        #expect(gaps(linked).isEmpty)
        let acting = message([.with { $0.image = .with { $0.imageURL = "https://example.com/a.gif"; $0.onClick.action = Self.vote } }])
        #expect(try card(acting).sections == [[.image(URL(string: "https://example.com/a.gif")!, aspect: 16.0 / 9, click: Card.Link(title: "", url: chat, action: Self.vote))]])
        #expect(gaps(acting).isEmpty)
    }
    /// A card's picture loads as the card names it: a size suffix makes Google's image proxy crop and enlarge a GIF.
    @Test func aCardPictureLoadsWithoutASizeSuffix() {
        let proxy = URL(string: "https://lh3.googleusercontent.com/proxy/abc")!
        #expect(RemoteImage.sized(proxy, px: 0) == proxy)
        #expect(RemoteImage.sized(proxy, px: 64) != proxy)
    }
}

extension AuthTests {
    /// An app or the server refusing a card's action answers status 4 with why: the backend throws it, and the store
    /// says it as Google Chat does, naming the app.
    @Test func aRefusedCardActionSaysWhy() async throws {
        let refusal = Dynamite_ClickCardResponse.with { $0.field1 = 4; $0.status = .with { $0.code = 7; $0.message = "Not allowed here" } }
        let (backend, _) = try await Self.connected([try Self.proto(refusal)])
        await #expect(throws: DynamiteError.appRefused("Not allowed here")) {
            _ = try await backend.clickCard("dm/a/t1/h1", card: "c1", action: CardActionTests.reply, inputs: [])
        }
    }
}

extension CardActionTests {
    @MainActor @Test func theStoreNamesTheAppThatRefused() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let message = try #require(store.messages.first)
        await fake.refuseNextCardClick("Not allowed here")
        await store.clickCard(message, card: nil, action: Self.reply, inputs: [])
        #expect(store.error == "\(message.sender.name) is unable to process your request. Not allowed here")
    }
}
