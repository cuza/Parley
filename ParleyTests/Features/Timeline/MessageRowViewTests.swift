import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct MessageRowViewTests {
    let row = RowFixtures.row(RowFixtures.long, newDay: true) {
        $0.quote = QuotedMessage(sender: "Sam", text: "the original")
        $0.attachments = [
            Attachment.fixture(.image, width: 1200, height: 800), Attachment(name: "notes.txt", kind: .file),
        ]
        $0.reactions = [Reaction(emoji: "👍", people: ["me"]), Reaction(emoji: "🎉", people: ["alex"])]
        $0.replyCount = 2
        $0.delivery = .failed
    }
    private func view(width: CGFloat, own: Bool = false, actions: MessageRowActions = MessageRowActions())
        -> MessageRowView
    {
        let view = MessageRowView()
        view.configure(row, own: own, kind: .space, meID: "me", actions: actions)
        view.frame = CGRect(
            x: 0, y: 0, width: width, height: RowLayout.make(row, width: width, own: own, kind: .space).height)
        view.layoutSubtreeIfNeeded()
        return view
    }
    private func expectPlaced(_ view: MessageRowView, width: CGFloat, own: Bool = false) {
        let layout = RowLayout.make(row, width: width, own: own, kind: .space)
        #expect(view.rowLayout == layout)
        let pairs: [(NSView, CGRect?)] =
            [
                (view.dateLabel, layout.dateHeader), (view.avatarView, layout.avatar), (view.nameLabel, layout.name),
                (view.quoteView, layout.quote), (view.quoteSenderLabel, layout.quoteSender),
                (view.quoteTextLabel, layout.quoteText),
                (view.textView, layout.text), (view.repliesLink, layout.replies), (view.timeLabel, layout.time),
                (view.retryLink, layout.retry),
            ]
            + zip(view.attachmentViews, layout.attachments).map { ($0, $1) }
            + zip(view.reactionPills, layout.reactions).map { ($0, $1) }
        for (subview, frame) in pairs {
            #expect(subview.isHidden == (frame == nil))
            if let frame {
                #expect(subview.frame == frame, "\(type(of: subview)) at \(subview.frame), layout \(frame)")
            }
        }
        #expect(view.attachmentViews.count == 2 && view.reactionPills.count == 2)
        let bubble = view.bubbleView.frame
        #expect(bubble.height == layout.bubble.height && bubble.width == layout.bubble.width + RowLayout.tailWidth)
        #expect(bubble.contains(layout.bubble))
    }

    /// A jump to a message flashes its whole row once (Telegram's), not again while it stays highlighted; another row
    /// shown in the same view doesn't inherit the flash.
    @Test func aJumpFlashesTheRowOnce() {
        let view = MessageRowView()
        view.configure(row, own: false, kind: .space, meID: "me", highlighted: true, actions: MessageRowActions())
        #expect(view.flash.animation(forKey: "flash") != nil)
        view.flash.removeAllAnimations()
        view.configure(row, own: false, kind: .space, meID: "me", highlighted: true, actions: MessageRowActions())
        #expect(view.flash.animation(forKey: "flash") == nil)
        view.configure(row, own: false, kind: .space, meID: "me", highlighted: false, actions: MessageRowActions())
        view.configure(row, own: false, kind: .space, meID: "me", highlighted: true, actions: MessageRowActions())
        #expect(view.flash.animation(forKey: "flash") != nil)
        let other = TimelineRow(
            message: .fixture("other", id: "other", from: RowFixtures.alex), begins: true, ends: true, newDay: false)
        view.configure(other, own: false, kind: .space, meID: "me", actions: MessageRowActions())
        #expect(view.flash.animation(forKey: "flash") == nil)
    }

    /// The full date shows on the time only: a tooltip over the whole row got in the way of reading.
    @Test func theFullDateIsOnTheTimeNotTheRow() {
        let row = view(width: 600)
        #expect(row.toolTip == nil)
        #expect(row.timeLabel.toolTip?.isEmpty == false)
    }
    @Test func everySubviewSitsAtItsLayoutFrame() {
        expectPlaced(view(width: 640), width: 640)
        expectPlaced(view(width: 640, own: true), width: 640, own: true)
    }
    @Test func aWidthChangeMovesTheSubviews() {
        let view = view(width: 900)
        let wideText = view.textView.frame
        view.setFrameSize(NSSize(width: 340, height: RowLayout.make(row, width: 340, own: false, kind: .space).height))
        view.layoutSubtreeIfNeeded()
        expectPlaced(view, width: 340)
        #expect(view.textView.frame != wideText)
    }
    @Test func noAutoLayout() {
        let view = view(width: 640)
        #expect(view.constraints.isEmpty)
        for subview in view.subviews {
            #expect(subview.translatesAutoresizingMaskIntoConstraints && subview.autoresizingMask == [])
        }
    }
    @Test func reconfiguringReusesTheViewForAnotherRow() {
        let view = view(width: 640)
        let plain = RowFixtures.row("short", begins: false)
        view.configure(plain, own: true, kind: .space, meID: "me", actions: MessageRowActions())
        view.layoutSubtreeIfNeeded()
        #expect(view.attachmentViews.isEmpty && view.reactionPills.isEmpty)
        #expect(view.rowLayout == RowLayout.make(plain, width: 640, own: true, kind: .space))
        #expect(view.textView.string == "short" && view.quoteView.isHidden && view.retryLink.isHidden)
    }
    @Test func pillsAndLinksCallTheirActions() {
        var calls: [String] = []
        var actions = MessageRowActions()
        actions.react = { emoji, _ in calls.append(emoji) }
        actions.openThread = { _ in calls.append("thread") }
        actions.retry = { _ in calls.append("retry") }
        let view = view(width: 640, actions: actions)
        _ = view.reactionPills[1].accessibilityPerformPress()
        _ = view.repliesLink.accessibilityPerformPress()
        _ = view.retryLink.accessibilityPerformPress()
        #expect(calls == ["🎉", "thread", "retry"])
    }
}
