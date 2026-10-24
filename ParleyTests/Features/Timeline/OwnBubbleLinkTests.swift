import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct OwnBubbleLinkTests {
    @Test func linksInOwnBubblesTakeItsAccentAndAreUnderlined() {
        let view = MessageRowView()
        let message = Message.fixture("see https://plane.so now", from: .fixture("me", name: "Me"))
        view.configure(
            TimelineRow.rows([message])[0], own: true, kind: .direct, meID: "me", actions: MessageRowActions())
        #expect(view.textView.linkTextAttributes?[.foregroundColor] as? NSColor == BubblePalette.ownAccent)  // white, or a deeper shade of a pale bubble
        #expect(view.textView.linkTextAttributes?[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        view.configure(
            TimelineRow.rows([.fixture("https://x.com", id: "n")])[0],
            own: false, kind: .direct, meID: "me", actions: MessageRowActions())
        #expect(view.textView.linkTextAttributes?[.foregroundColor] as? NSColor != .white)
    }
    @Test func aQuoteOnMyBubbleTakesItsAccent() {
        let view = MessageRowView()
        let message = Message.fixture("yes", from: .fixture("me", name: "Me")) {
            $0.quote = QuotedMessage(sender: "Sam", text: "the original")
        }
        view.configure(
            TimelineRow.rows([message])[0], own: true, kind: .direct, meID: "me", actions: MessageRowActions())
        #expect(view.quoteView.bar == BubblePalette.ownAccent)
    }
}
