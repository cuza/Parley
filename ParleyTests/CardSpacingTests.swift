import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parley

/// A card laid out as a form: text fields one control high (a multi-line one grows with what it holds), one line at
/// most between sections (none when the card draws its own dividers), none at the card's edges, room round each
/// section in a dialog, text beside a lone button filling the row up to it, and the height `CardLayout` reserves
/// matching what is drawn. Content-free shapes of what apps send.
@MainActor struct CardSpacingTests {
    private static func text(_ string: String) -> Dynamite_FormattedText { .with { $0.segments = [.with { $0.run.text = string }] } }
    private static let send = Data(try! Dynamite_CardAction.with { $0.function = "f" }.serializedBytes() as [UInt8])
    private static func field(_ name: String, multiline: Bool = true) -> Dynamite_CardWidget {
        .with { $0.textInput = .with { $0.name = name; $0.label = name.uppercased(); $0.type = multiline ? 1 : 0 } }
    }
    private static let divider = Dynamite_CardWidget.with { $0.divider = .init() }
    /// A dialog shaped like a poll's: fields, a divider-only section between the others, a header with check boxes, a
    /// collapsed section, text beside a button in two columns, and a divider last; the card draws no section lines.
    static let pollLike = Dynamite_Card.with { c in
        c.sectionDividerStyle = 2
        c.sections = [
            .with { $0.widgets = [field("q")] },
            .with { $0.collapsible = true; $0.uncollapsibleWidgetsCount = 2; $0.widgets = [field("a"), field("b"), field("c")]
                    $0.collapseControl.expandButton.textButton.label = text("More"); $0.collapseControl.collapseButton.textButton.label = text("Less") },
            .with { $0.widgets = [divider] },
            .with { $0.header = "H"; $0.widgets = [.with { $0.selectionInput = .with { $0.name = "o"; $0.type = 0; $0.items = [.with { $0.text = "X"; $0.value = "x" }] } }] },
            .with { $0.widgets = [divider] },
            .with { $0.widgets = [.with { $0.columns.columns = [
                .with { $0.horizontalAlignment = 1; $0.widgets = [.with { $0.textParagraph.text = text("Some text beside a button") }] },
                .with { $0.horizontalAlignment = 3; $0.widgets = [.with { $0.buttons = [.with { $0.textButton = .with { $0.label = text("B"); $0.onClick.action = send } }] }] },
            ] }] },
            .with { $0.widgets = [divider] },
        ]
    }

    // MARK: Mapping

    /// Google Chat sends its multi-line type on one-line fields too: both start one control high; text grows one.
    @Test func aMultiLineFieldStartsOneLineHigh() {
        let single = Card.Field(name: "a", label: "", value: ""), multi = Card.Field(name: "a", label: "", value: "", multiline: true)
        #expect(CardLayout.height(.field(multi), width: 400) == CardLayout.height(.field(single), width: 400))
        var three = multi; three.value = "1\n2\n3"
        #expect(CardLayout.lines(three, width: 380) == 3)
        #expect(CardLayout.height(.field(three), width: 400) > CardLayout.height(.field(multi), width: 400) + 20)
        var many = multi; many.value = Array(repeating: "x", count: 20).joined(separator: "\n")
        #expect(CardLayout.lines(many, width: 380) == CardLayout.maxLines)
    }
    /// A card that draws no section lines keeps its own dividers, but never one at the bottom; a card with lines drops
    /// a divider-only section (the section's line already splits them) and a divider next to a section's line.
    @Test func dividersNeverDoubleOrTrail() {
        let dialog = DynamiteMapper.dialog(Self.pollLike, message: "dm/d/m1/m1").card
        #expect(dialog.dividers == false)
        let kinds = dialog.sections.map { $0.map { item -> String in
            switch item { case .divider: "-"; case .field: "f"; case .collapse: "c"; case .row: "r"; case .choice: "o"; case .text: "t"; default: "?" }
        }.joined() }
        #expect(kinds == ["f", "fffc", "-", "to", "-", "r"])
        var lined = Self.pollLike; lined.sectionDividerStyle = 0
        let card = DynamiteMapper.dialog(lined, message: "dm/d/m1/m1").card
        #expect(card.dividers == nil)
        #expect(!card.sections.flatMap { $0 }.contains(.divider))
        #expect(DynamiteMapper.tidy([[.divider, .text("a", []), .divider, .divider], [.divider, .text("b", []), .divider]], lines: false)
                == [[.text("a", []), .divider], [.text("b", [])]])
    }
    /// Text beside a single button in two columns is a row with the button at its end.
    @Test func textBesideAButtonIsARowWithAnEndButton() throws {
        let card = DynamiteMapper.dialog(Self.pollLike, message: "dm/d/m1/m1").card
        guard case .row(_, _, _, let text, _, _, let button?, _, _)? = card.sections.last?.first else { Issue.record("\(card.sections.last ?? [])"); return }
        #expect(text == "Some text beside a button" && button.title == "B")
    }

    // MARK: Hosted

    private func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    private func host<V: View>(_ view: V, size: CGSize) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }
    /// Each text field is one control high, as tall as the slot kept for it.
    @Test func everyEmptyFieldIsOneControlHigh() throws {
        let card = Card(sections: [[.field(Card.Field(name: "a", label: "A", value: "")), .field(Card.Field(name: "b", label: "B", value: "", multiline: true))]])
        let view = host(CardView(card: card), size: CardLayout.size(card, maxWidth: 400))
        let fields = all(view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(fields.count == 2 && CardLayout.fieldControl < 30)
        for field in fields {
            #expect(field.frame.height <= CardLayout.fieldControl + 0.5, "\(field.frame)")
            #expect(!field.isBezeled && !field.isBordered)   // one outline: the card's own, not the field's too
        }
    }
    /// A row's end control sits at the row's trailing edge, its text taking the rest, however short the text. (The end
    /// button shares the slot; a switch is used here as AppKit hosts it as a view of its own.)
    @Test(arguments: [560.0, 420.0, 320.0]) func aRowsEndControlSitsAtItsTrailingEdge(width: Double) throws {
        let toggle = Card.Toggle(name: "t", value: "1", on: false, checkbox: false)
        let card = Card(sections: [[.row(icon: nil, round: false, label: nil, text: "Short", formatting: [], toggle: toggle)]])
        let size = CardLayout.size(card, maxWidth: width)
        let view = host(CardView(card: card), size: size)
        let box = try #require(all(view).first { $0 is NSControl && !($0 is NSTextField) }, "\(all(view).map { type(of: $0) })"), frame = box.convert(box.bounds, to: view)
        let end = size.width - CardLayout.pad   // the switch is centred in its slot, a few points narrower than it
        #expect(frame.maxX <= end + 0.5 && frame.maxX >= end - 4 && frame.minX >= end - CardLayout.toggleWidth(toggle) - 0.5, "\(frame) in \(size)")
    }
    /// The dialog's sheet: the poll-like card sits inside the height measured for it, its last widget near the bottom,
    /// and sections in a card without lines keep room between them.
    @Test(arguments: [560.0, 420.0, 320.0]) func aDialogsMeasuredHeightIsWhatIsDrawn(width: Double) throws {
        let card = DialogLayout.card(DynamiteMapper.dialog(Self.pollLike, message: "dm/d/m1/m1"))
        let inner = width - 2 * DialogLayout.margin
        let height = CardLayout.boxHeight(card, width: inner)
        let view = host(CardView(card: card, footer: (nil, nil)), size: CGSize(width: width, height: height + 2 * DialogLayout.margin + 200))
        let texts = all(view).filter { $0 is NSTextView || ($0 as? NSTextField)?.isEditable == true }.map { $0.convert($0.bounds, to: view) }
        let top = try #require(texts.map(\.minY).min()), bottom = try #require(texts.map(\.maxY).max())
        #expect(top >= DialogLayout.margin - 0.5)
        // The last row's text, centred on its button, ends within a few points of the measured bottom.
        #expect(bottom <= DialogLayout.margin + height + 0.5 && bottom >= DialogLayout.margin + height - CardLayout.buttons, "\(bottom) vs \(height)")
        // Fields one control high, a gap of at least `gap` between widgets.
        let fields = all(view).compactMap { $0 as? NSTextField }.filter(\.isEditable).map { $0.convert($0.bounds, to: view) }.sorted { $0.minY < $1.minY }
        #expect(fields.count == 3)   // the collapsed section's third is hidden
        for field in fields { #expect(field.height <= CardLayout.fieldControl + 0.5) }
        // First section's field, then the next section's labelled field: a section's room apart at least.
        #expect(fields[1].minY - fields[0].maxY >= 2 * CardLayout.sectionRoom(card) + CardLayout.labelHeight, "\(fields)")
    }
    /// A message card's measured height holds what it draws: its last text ends a pad above the bottom.
    @Test(arguments: [560.0, 420.0, 320.0]) func aMessageCardsMeasuredHeightIsWhatIsDrawn(width: Double) throws {
        let card = Card(sections: [[.text("Title", []), .divider, .field(Card.Field(name: "a", label: "A", value: "", multiline: true))],
                                   [.text("Last paragraph that may wrap at a narrow width", [])]])
        let size = CardLayout.size(card, maxWidth: width)
        let view = host(CardView(card: card), size: size)
        let last = try #require(all(view).compactMap { $0 as? NSTextView }.map { $0.convert($0.bounds, to: view) }.max { $0.maxY < $1.maxY })
        #expect(abs(last.maxY - (size.height - CardLayout.pad)) <= 1, "\(last) in \(size)")
    }
}
