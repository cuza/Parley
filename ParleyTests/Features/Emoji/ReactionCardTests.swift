import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct ReactionCardTests {
    private let load: (ParleyDomain.Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }
    @Test func theCardShowsAfterTheDelayAndTakesTheNamesInPlace() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: false)
        let pill = NSView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        let other = NSView(frame: .zero)
        window.contentView?.addSubview(pill)
        let card = ReactionCard()
        card.delay = .milliseconds(10)
        let thumbs = ReactionCardView(
            reaction: Reaction(emoji: "👍", people: ["me", "a"]), names: ChatStore.reactorsLine(names: [], count: 2),
            load: load)
        card.hover(pill, thumbs)
        #expect(!card.isShown)
        await eventually { card.isShown }
        #expect(card.isShown && card.content?.names == "2 people")
        var named = thumbs
        named.names = "Alex and You"
        card.update(other, ReactionCardView(reaction: thumbs.reaction, names: "someone else", load: load))  // another pill's: ignored
        card.update(pill, named)
        #expect((card.panel?.contentView as? NSHostingView<ReactionCardView>)?.rootView.names == "Alex and You")
        card.hide(other)
        #expect(card.isShown)
        card.hide(pill)
        #expect(!card.isShown)
        #expect(card.panel?.ignoresMouseEvents == true)
    }
}
