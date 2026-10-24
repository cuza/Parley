import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

/// "1 draft" under a thread's first message, beside its reply count.
@MainActor
struct DraftLabelTests {
    @Test func theRepliesLineSaysADraftWaits() {
        #expect(RowLayout.repliesText(2, draft: true).string == "2 replies · 1 draft")
        #expect(RowLayout.repliesText(0, draft: true).string == "1 draft")
        #expect(RowLayout.repliesText(1).string == "1 reply")
    }
    @Test func aDraftShowsTheLineEvenWithoutReplies() {
        var row = RowFixtures.row("hello")
        #expect(RowLayout.make(row, width: 640, own: false, kind: .space).replies == nil)
        row.draft = true
        let layout = RowLayout.make(row, width: 640, own: false, kind: .space)
        #expect(layout.replies != nil && layout.bubble.contains(layout.replies!))
        let view = MessageRowView()
        view.configure(row, own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.frame = CGRect(x: 0, y: 0, width: 640, height: layout.height)
        view.layoutSubtreeIfNeeded()
        #expect(
            !view.repliesLink.isHidden && view.repliesLink.frame == layout.replies
                && view.repliesLink.text.string == "1 draft")
    }
    @Test func timelineRowsMarkThreadsWithDrafts() {
        #expect(
            TimelineRow.rows([.fixture("x", id: "h"), .fixture("y", id: "o")], drafts: ["h"]).map(\.draft) == [
                true, false,
            ])
    }
}
