import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// How a card lays out: its width, byline, rows, labels, paragraphs and buttons.
struct CardLayoutTests: CardMessageFixtures {
    /// In a wide window a card is as wide as a bubble can be, as web draws an app's card across the message column.
    @Test func aCardIsAsWideAsTheWidestBubble() {
        let card = Card(sections: [[.text("A description long enough to need the room", [], lines: 2)]])
        let row = RowFixtures.row("https://example.com") {
            $0.attachments = [Attachment(name: "Card", kind: .card, card: card)]
        }
        let layout = RowLayout.make(row, width: 1150, own: false, kind: .space)
        #expect(layout.attachments[0].width == RowLayout.maxBubble)
    }
    /// Web's byline: "By" regular, the app's name bold.
    @Test func theBylineBoldsTheAppName() {
        let line = CardView.bylineText("Example")
        #expect(line.characters.count == "By Example".count)
        #expect(line.runs.count == 2 && line.runs.last.map { String(line[$0.range].characters) } == "Example")
        #expect(
            line.runs.last?.inlinePresentationIntent == .stronglyEmphasized
                && line.runs.first?.inlinePresentationIntent == nil)
    }
    /// A row whose text doesn't wrap (wrap_text off) keeps its title on one line, cut with "…", as web does.
    @Test func aRowThatDoesNotWrapKeepsItsTitleOnOneLine() throws {
        func row(wrap: Bool) throws -> [TextStyleRange] {
            let card = Dynamite_Card.with {
                $0.sections = [
                    .with {
                        $0.widgets = [
                            .with {
                                $0.decoratedText = .with {
                                    $0.text = text("A pull request title")
                                    $0.bottomLabel = text("Open")
                                    $0.wrapText = wrap
                                }
                            }
                        ]
                    }
                ]
            }
            guard
                case .row(_, _, _, _, let formatting, _, _, _, _)? = try mapped(message(card: card)).attachments.first?
                    .card?.sections.first?.first
            else { return [] }
            return formatting
        }
        #expect(try row(wrap: false).contains(TextStyleRange(style: .nowrap, start: 0, length: 20)))
        #expect(try !row(wrap: true).contains { $0.style == .nowrap })
        let long = String(repeating: "A long pull request title ", count: 10)
        #expect(
            NativeMessageText.size(
                of: long, formatting: [TextStyleRange(style: .nowrap, start: 0, length: (long as NSString).length)],
                width: 300
            ).height
                == NativeMessageText.size(of: "A", width: 300).height)
    }
    /// A label's coloured runs ("Open" in green) keep their colour; runs in the default text grey take the label's grey.
    @Test func aLabelKeepsItsColouredRuns() throws {
        func run(_ string: String, light: UInt32, dark: UInt32) -> Dynamite_TextSegment {
            .with {
                $0.run = .with {
                    $0.text = string
                    $0.colorPair = .with {
                        $0.light = light
                        $0.dark = dark
                    }
                }
            }
        }
        let card = Dynamite_Card.with {
            $0.sections = [
                .with {
                    $0.widgets = [
                        .with {
                            $0.decoratedText = .with {
                                $0.text = text("Title")
                                $0.wrapText = true
                                $0.bottomLabel = .with {
                                    $0.segments = [
                                        run("Open", light: 0x1AA64A, dark: 0x6AF69A),
                                        run(" · repo", light: 0x212121, dark: 0xD5D5D5),
                                    ]
                                }
                            }
                        }
                    ]
                }
            ]
        }
        guard
            case .row(_, _, _, let string, let formatting, _, _, _, _)? = try mapped(message(card: card)).attachments
                .first?.card?.sections.first?.first
        else {
            Issue.record("no row")
            return
        }
        #expect(string == "Title\nOpen · repo")
        #expect(formatting.last == TextStyleRange(style: .color(0xFF1A_A64A), start: 6, length: 4))  // after the label's grey, so it wins
        #expect(formatting.filter { if case .color = $0.style { true } else { false } }.count == 2)
    }
    /// A paragraph cut to its lines ends in "…" with "Show more" under it; open, it shows all of it and "Show less".
    @Test func aCutParagraphEndsInAnEllipsisAndOpensInPlace() {
        let long = "## What\n\n" + String(repeating: "The storage module then creates no CDN resources. ", count: 8)
        let shown = try? #require(CardLayout.cut(long, [], lines: 2, width: 300))
        #expect(shown?.hasSuffix("…") == true && shown?.hasPrefix("## What") == true)
        #expect(CardLayout.cut("Short", [], lines: 2, width: 300) == nil)
        let card = Card(sections: [[.text(long, [], lines: 2)]])
        let closed = CardLayout.size(card, maxWidth: 300).height
        let open = CardLayout.size(card, maxWidth: 300, expanded: true).height
        #expect(
            open > closed && closed > CardLayout.size(Card(sections: [[.text("## What", [])]]), maxWidth: 300).height)
        let row = RowFixtures.row("https://example.com") {
            $0.attachments = [Attachment(name: "Card", kind: .card, card: card)]
        }
        #expect(
            RowLayout.make(
                TimelineRow(message: row.message, begins: true, ends: true, newDay: false, transcriptOpen: true),
                width: 600, own: false, kind: .space
            ).attachments[0].height
                > RowLayout.make(row, width: 600, own: false, kind: .space).attachments[0].height)
    }
    /// Buttons in columns share one row, as web lays out a Drive comment's: Reply and Resolve at the start, Open at the
    /// end. A button keeps its type: outlined unless it says filled.
    @Test func columnsOfButtonsShareOneRow() throws {
        func button(_ label: String, _ onClick: Dynamite_CardOnClick, type: Int32 = 1) -> Dynamite_CardButton {
            .with {
                $0.textButton = .with {
                    $0.label = text(label)
                    $0.onClick = onClick
                    $0.type = type
                }
            }
        }
        let act = Dynamite_CardOnClick.with { $0.action = Data([1]) }
        let card = Dynamite_Card.with {
            $0.sections = [
                .with {
                    $0.widgets = [
                        .with {
                            $0.columns = .with {
                                $0.columns = [
                                    .with {
                                        $0.horizontalAlignment = 1
                                        $0.widgets = [
                                            .with { $0.buttons = [button("Reply", act), button("Resolve", act)] }
                                        ]
                                    },
                                    .with {
                                        $0.horizontalAlignment = 3
                                        $0.widgets = [
                                            .with {
                                                $0.buttons = [
                                                    button("Open", link("https://docs.example.com/d/1"), type: 2)
                                                ]
                                            }
                                        ]
                                    },
                                ]
                            }
                        }
                    ]
                }
            ]
        }
        let shown = try mapped(message(card: card))
        let chat = try #require(ChatLink.url(message: shown.id))
        #expect(
            shown.attachments.first?.card?.sections == [
                [
                    .links([
                        Card.Link(title: "Reply", url: chat), Card.Link(title: "Resolve", url: chat),
                        Card.Link(
                            title: "Open", url: URL(string: "https://docs.example.com/d/1")!, trailing: true,
                            filled: true),
                    ])
                ]
            ])
    }
}
