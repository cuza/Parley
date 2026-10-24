import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// The newest messages and the floating composer: a reader at the bottom stays just above it as rows and the composer
/// change size, and leaving or returning to the bottom is reported.
@MainActor struct MessageTableBottomTests {
    private typealias Harness = MessageTableHarness
    private func messages(_ range: Range<Int>) -> [Message] { MessageTableHarness.messages(range) }

    /// Hosted as in the app: a read receipt arrives for the newest message ("Seen" under it), which makes its row
    /// taller; a reader at the bottom must still see it above the composer.
    @Test func aReceiptOnTheNewestMessageKeepsItAboveTheComposer() throws {
        let coordinator = MessageTable.Coordinator()
        let shown = messages(0..<40)
        let newest = try #require(shown.last)
        func content(seen: Bool) -> some View {
            MessageTableHost(
                coordinator: coordinator,
                table: MessageTable(
                    rows: TimelineRow.rows(shown, seen: seen ? [newest.id: ["Alex"]] : [:]),
                    meID: "me", kind: .direct, actions: MessageRowActions(), nearTop: {}, bottomInset: 60))
        }
        let host = NSHostingView(rootView: AnyView(content(seen: false)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle()
        let table = try #require(coordinator.table)
        let scroll = try #require(coordinator.scroll)
        let before = table.rect(ofRow: table.numberOfRows - 1).height
        host.rootView = AnyView(content(seen: true))
        settle()
        let rowsEnd = table.rect(ofRow: table.numberOfRows - 1).maxY
        #expect(table.rect(ofRow: table.numberOfRows - 1).height > before, "the receipt adds a line")
        #expect(table.frame.height == rowsEnd, "table \(table.frame.height), rows end at \(rowsEnd)")
        let gap = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom - rowsEnd
        #expect(abs(gap) < 0.5, "the newest message ends \(gap) pt from the composer")
    }
    /// Seen live as a wiggle: a read receipt moving to the newest message re-measured rows with NSTableView's height
    /// animation while the scroll position was already final, so rows slid into place.
    @Test func aReceiptMovingDoesNotAnimateRows() {
        let harness = Harness()
        let shown = messages(0..<40)
        harness.show(shown, seen: [shown[36].id: ["Alex"]], bottomInset: 60)
        harness.show(shown, seen: [shown[39].id: ["Alex"]], bottomInset: 60)
        func keys(_ view: NSView) -> [String] { (view.layer?.animationKeys() ?? []) + view.subviews.flatMap(keys) }
        let animating = (0..<harness.table.numberOfRows).filter {
            harness.table.rowView(atRow: $0, makeIfNecessary: false).map(keys)?.isEmpty == false
        }
        #expect(animating.isEmpty, "rows animating: \(animating)")
        #expect(abs(harness.gapAboveComposer) < 0.5)
    }
    @Test func rowsArrivingBeforeTheTableHasAWidthStillOpenAtTheNewest() throws {
        let coordinator = MessageTable.Coordinator()
        let scroll = MessageTable.makeScrollView(coordinator, identifier: "t")  // not in a window yet: no width
        coordinator.update(
            MessageTable(
                rows: TimelineRow.rows(messages(0..<40)), meID: "me", kind: .space, actions: MessageRowActions(),
                nearTop: {}))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let table = try #require(scroll.documentView as? NSTableView)
        #expect(
            scroll.documentVisibleRect.maxY >= table.bounds.height - 1,
            "visible \(scroll.documentVisibleRect), table \(table.bounds.height)")
    }
    /// Seen live: a conversation opened with its newest rows behind the floating composer. Rows that arrive before the
    /// table has a width are measured later and grow; the reader must still end just above the composer.
    @Test func rowsMeasuredAfterArrivingStillEndAboveTheComposer() throws {
        let coordinator = MessageTable.Coordinator()
        let scroll = MessageTable.makeScrollView(coordinator, identifier: "t")
        coordinator.update(
            MessageTable(
                rows: TimelineRow.rows(messages(0..<40)), meID: "me", kind: .space, actions: MessageRowActions(),
                nearTop: {}, bottomInset: 60))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let table = try #require(scroll.documentView as? NSTableView)
        let gap = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom - table.bounds.height
        #expect(
            abs(gap) < 0.5,
            "newest message ends \(gap) pt from the composer; clip \(scroll.contentView.bounds), table \(table.bounds.height)"
        )
    }
    @Test func aTransientNarrowLayoutDoesNotUnpinTheBottom() {
        // SwiftUI briefly lays the timeline out tiny (130 x 40 pt) while a window first appears.
        let harness = Harness()
        harness.show(messages(0..<16))
        harness.window.setContentSize(NSSize(width: 130, height: 40))
        harness.settle()
        harness.window.setContentSize(NSSize(width: 800, height: 600))
        harness.settle()
        #expect(
            harness.scroll.documentVisibleRect.maxY >= harness.table.bounds.height - 1,
            "visible \(harness.scroll.documentVisibleRect), table \(harness.table.bounds.height)")
    }
    @Test func aNewMessageKeepsAReaderAtTheBottomThere() {
        let harness = Harness()
        harness.show(messages(0..<40))
        #expect(harness.scroll.documentVisibleRect.maxY >= harness.table.bounds.height - 1)
        harness.show(messages(0..<41))
        #expect(harness.scroll.documentVisibleRect.maxY >= harness.table.bounds.height - 1)
    }
    @Test func reportsLeavingAndReturningToTheNewestMessages() async {
        let harness = Harness()
        harness.show(messages(0..<80))
        harness.scroll(to: 0)
        await eventually { harness.atBottom.last == false }  // reported after the current update
        harness.show(messages(0..<80), scrollRequest: 1)  // the scroll-to-bottom button
        await eventually {
            harness.settle()
            return harness.atBottom.last == true
        }
    }

    // The composer floats over the timeline: the table gets a bottom inset of the composer's height.
    @Test func aPinnedReaderStaysJustAboveTheComposerAsItGrowsAndShrinks() {
        let harness = Harness()
        harness.show(messages(0..<80))
        for inset: CGFloat in [120, 200, 60, 0, 90] {
            harness.show(messages(0..<80), bottomInset: inset)
            #expect(harness.scroll.contentInsets.bottom == inset)
            #expect(
                abs(harness.gapAboveComposer) < 0.5,
                "inset \(inset): newest message ends \(harness.gapAboveComposer) pt from the composer")
        }
        harness.show(messages(0..<81), bottomInset: 90)  // a new message while pinned
        #expect(abs(harness.gapAboveComposer) < 0.5)
    }
    @Test func aShortConversationKeepsItsFirstMessageInView() {
        let harness = Harness()
        harness.show(messages(0..<3), bottomInset: 200)
        #expect(
            harness.table.rect(ofRow: 0).minY >= harness.clip.minY,
            "first row \(harness.table.rect(ofRow: 0)), clip \(harness.clip), table \(harness.table.bounds)")
    }
    @Test func theComposerResizingDoesNotMoveAReaderScrolledUp() {
        let harness = Harness()
        harness.show(messages(0..<80), bottomInset: 60)
        harness.scroll(to: 400)
        let top = harness.clip.minY
        harness.show(messages(0..<80), bottomInset: 180)
        #expect(harness.clip.minY == top)
        harness.show(messages(0..<80), bottomInset: 40)
        #expect(harness.clip.minY == top)
    }
    @Test func scrollingTheNewestMessageBehindTheComposerUnpins() {
        let harness = Harness()
        harness.show(messages(0..<80), bottomInset: 200)
        harness.scroll(to: harness.clip.minY - 100)  // the newest message is now under the composer
        harness.show(messages(0..<81), bottomInset: 200)
        #expect(harness.gapAboveComposer < -50, "a reader who scrolled up is not pulled down")
        harness.scroll(to: harness.table.bounds.height + 200 - harness.clip.height - 10)  // back within reach of the bottom
        harness.show(messages(0..<82), bottomInset: 200)
        #expect(abs(harness.gapAboveComposer) < 0.5)
    }
    @Test func atBottomCountsOnlyThePartOfTheViewAboveTheComposer() async {
        let harness = Harness()
        harness.show(messages(0..<80), bottomInset: 200)
        let visible = harness.clip.height - 200
        // Within one full view of the newest message, but more than one uncovered view away from it.
        harness.scroll(to: harness.table.bounds.height - 2 * harness.clip.height + 200)
        #expect(harness.clip.maxY - 200 < harness.table.bounds.height - visible)
        await eventually { harness.atBottom.last == false }
        harness.show(messages(0..<80), scrollRequest: 1, bottomInset: 200)
        await eventually {
            harness.settle()
            return harness.atBottom.last == true
        }
        #expect(
            abs(harness.gapAboveComposer) < 0.5, "scroll to bottom rests the newest message just above the composer")
    }
}
