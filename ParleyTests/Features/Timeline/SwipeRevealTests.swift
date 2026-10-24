import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct SwipeRevealTests {
    @Test func swipingSlidesTheRowAndRevealsTheReplyArrow() {
        let view = MessageRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        view.configure(
            TimelineRow.rows([.fixture()])[0],
            own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.layoutSubtreeIfNeeded()
        #expect(view.replyArrow.alphaValue == 0)
        view.setSwipe(offset: -60, stage: nil)
        #expect(view.bounds.origin.x == 60)  // content slides left with the fingers
        #expect(view.replyArrow.alphaValue > 0 && view.replyArrow.alphaValue < 1)
        #expect(view.visibleRect.contains(view.replyArrow.frame))  // the arrow sits in the revealed strip
        #expect(view.replyArrow.image?.accessibilityDescription == "Reply")
        view.setSwipe(offset: -120, stage: .quote)
        #expect(view.replyArrow.alphaValue == 1 && view.replyArrow.image?.accessibilityDescription == "Reply")
        view.setSwipe(offset: -200, stage: .thread)  // further: the icon becomes the thread's
        #expect(view.replyArrow.alphaValue == 1 && view.replyArrow.image?.accessibilityDescription == "Reply in Thread")
        #expect(view.visibleRect.contains(view.replyArrow.frame))
        view.setSwipe(offset: -150, stage: .quote)  // and back
        #expect(view.replyArrow.image?.accessibilityDescription == "Reply")
        view.setSwipe(offset: 0, stage: nil)
        #expect(view.bounds.origin.x == 0 && view.replyArrow.alphaValue == 0)
    }
}
