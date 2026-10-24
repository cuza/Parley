import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// The timeline table as its window or a side pane resizes it: rows re-measured for the new width, and the reader kept
/// where they were.
@MainActor struct MessageTableResizeTests {
    private typealias Harness = MessageTableHarness
    private func messages(_ range: Range<Int>) -> [Message] { MessageTableHarness.messages(range) }
    /// Hosted by SwiftUI as in the app: a side pane opening beside the timeline narrows it, its rows grow, and the
    /// newest message must still rest just above the composer.
    @Test func openingASidePaneKeepsThePinnedReaderAboveTheComposer() throws {
        let coordinator = MessageTable.Coordinator()
        let rows = TimelineRow.rows(messages(0..<40))
        func content(pane: Bool) -> some View {
            HStack(spacing: 0) {
                MessageTableHost(
                    coordinator: coordinator,
                    table: MessageTable(
                        rows: rows, meID: "me", kind: .space,
                        actions: MessageRowActions(), nearTop: {}, bottomInset: 60))
                if pane { Color.clear.frame(width: 300) }
            }
        }
        let host = NSHostingView(rootView: AnyView(content(pane: false)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle()
        for pane in [true, false, true] {
            host.rootView = AnyView(content(pane: pane))
            settle()
            let scroll = try #require(coordinator.scroll)
            let table = try #require(coordinator.table)
            let rowsEnd = table.rect(ofRow: table.numberOfRows - 1).maxY
            #expect(table.frame.height == rowsEnd, "pane \(pane): table \(table.frame.height), rows end at \(rowsEnd)")
            let gap = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom - rowsEnd
            #expect(abs(gap) < 0.5, "pane \(pane): newest message ends \(gap) pt from the composer")
        }
    }
    /// Hosted as in the app: a side pane opening in a window that keeps its size narrows the timeline; every row must
    /// be re-measured for the new width (bubbles that kept their old height clipped their text).
    @Test func aPaneNarrowingTheTimelineRemeasuresItsRows() throws {
        let coordinator = MessageTable.Coordinator()
        let shown = messages(0..<12)
        let rows = TimelineRow.rows(shown)
        func content(pane: Bool) -> some View {
            HStack(spacing: 0) {
                MessageTableHost(
                    coordinator: coordinator,
                    table: MessageTable(
                        rows: rows, meID: "me", kind: .space,
                        actions: MessageRowActions(), nearTop: {}, bottomInset: 60))
                if pane { Color.clear.frame(width: 321) }
            }
        }
        let host = NSHostingView(rootView: AnyView(content(pane: false)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 770, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle()
        for pane in [true, false] {
            host.rootView = AnyView(content(pane: pane))
            settle()
            let table = try #require(coordinator.table)
            for rowIndex in 0..<rows.count {
                let rect = table.rect(ofRow: rowIndex)
                let layout = RowLayout.make(
                    rows[rowIndex], width: table.bounds.width, own: rows[rowIndex].message.sender.id == "me",
                    kind: .space)
                #expect(
                    rect.height == layout.height,
                    "pane \(pane) row \(rowIndex): row \(rect.height), layout \(layout.height) at \(table.bounds.width)"
                )
            }
        }
    }
    @Test func afterAResizeEveryRowMatchesItsLayoutAndRowViewsFollow() {
        let harness = Harness()
        let shown = messages(0..<12)
        harness.show(shown)
        let rows = TimelineRow.rows(shown)
        for width in [800.0, 420, 900, 380] {
            harness.window.setContentSize(NSSize(width: width, height: 600))
            harness.settle()
            for rowIndex in 0..<rows.count {
                let rect = harness.table.rect(ofRow: rowIndex)
                let layout = RowLayout.make(
                    rows[rowIndex], width: harness.table.bounds.width, own: rows[rowIndex].message.sender.id == "me",
                    kind: .space)
                #expect(
                    rect.height == layout.height,
                    "width \(width) row \(rowIndex): row \(rect.height), layout \(layout.height)")
                if let view = harness.table.rowView(atRow: rowIndex, makeIfNecessary: false) {
                    #expect(view.frame == rect, "width \(width) row \(rowIndex): view \(view.frame), row \(rect)")
                }
            }
        }
    }
    /// Hosted as in the app: the window is resized step by step (narrower, then wider), as a drag (live: rows in view
    /// re-measured per step, everything at the end) or as programmatic frames (every row per step). Rows must not move
    /// on screen for no reason: a reader at the bottom keeps the newest message just above the composer, and a reader
    /// scrolled up keeps the first message fully in view at the same height, at every step and after the end, with
    /// no row sliding into place afterwards.
    private func resizeKeepsTheReadersPlace(live: Bool, scrolledUp: Bool, offset: CGFloat = 0) throws {
        let coordinator = MessageTable.Coordinator()
        let rows = TimelineRow.rows(messages(0..<120))
        let host = NSHostingView(
            rootView: MessageTableHost(
                coordinator: coordinator,
                table: MessageTable(
                    rows: rows, meID: "me", kind: .space,
                    actions: MessageRowActions(), nearTop: {}, bottomInset: 60)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle()
        let scroll = try #require(coordinator.scroll)
        let table = try #require(coordinator.table)
        func clip() -> NSRect { scroll.contentView.bounds }
        if scrolledUp {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.height / 2 + offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle()
        }
        // The first row wholly in view (the composer covers the bottom), and how far below the top of the view it is.
        let visible = table.rows(in: clip())
        let anchor = try #require(
            (visible.location..<visible.location + visible.length).first { table.rect(ofRow: $0).minY >= clip().minY })
        let id = rows[anchor].id
        let onScreen = table.rect(ofRow: anchor).minY - clip().minY
        func check(_ step: String) {
            func keys(_ view: NSView) -> [String] { (view.layer?.animationKeys() ?? []) + view.subviews.flatMap(keys) }
            let animating = (0..<table.numberOfRows).filter {
                table.rowView(atRow: $0, makeIfNecessary: false).map(keys)?.isEmpty == false
            }
            #expect(animating.isEmpty, "offset \(offset) \(step): rows animating into place: \(animating)")
            let misplaced = (0..<table.numberOfRows).filter { rowIndex in
                table.rowView(atRow: rowIndex, makeIfNecessary: false).map { $0.frame != table.rect(ofRow: rowIndex) }
                    ?? false
            }
            #expect(misplaced.isEmpty, "\(step): row views away from their rows: \(misplaced)")
            if scrolledUp {
                let index = coordinator.rows.firstIndex { $0.id == id }!
                let y = table.rect(ofRow: index).minY - clip().minY
                #expect(
                    abs(y - onScreen) <= 1,
                    "offset \(offset) \(step): the reader's message moved from \(onScreen) to \(y) pt below the top")
            } else {
                let gap = clip().maxY - scroll.contentInsets.bottom - table.rect(ofRow: table.numberOfRows - 1).maxY
                #expect(abs(gap) <= 1, "\(step): the newest message ends \(gap) pt from the composer")
            }
        }
        if live { coordinator.resizing = true }  // as during a drag (AppKit's `inLiveResize` can't be faked here)
        for width in Array(stride(from: 780, through: 400, by: -20)) + Array(stride(from: 420, through: 900, by: 20)) {
            window.setContentSize(NSSize(width: CGFloat(width), height: 600))
            settle()
            check("width \(width)")
        }
        if live {
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            settle()
        }
        check("after the resize")
    }
    @Test func aDragResizeKeepsTheNewestMessageAboveTheComposer() throws {
        try resizeKeepsTheReadersPlace(live: true, scrolledUp: false)
    }
    /// Offsets across a few rows, so that the row cut off at the top is sometimes a long one that re-wraps.
    @Test(arguments: stride(from: 0, through: 160, by: 20).map { CGFloat($0) })
    func aDragResizeKeepsAReaderScrolledUpInPlace(offset: CGFloat) throws {
        try resizeKeepsTheReadersPlace(live: true, scrolledUp: true, offset: offset)
    }
    @Test func aProgrammaticResizeKeepsTheNewestMessageAboveTheComposer() throws {
        try resizeKeepsTheReadersPlace(live: false, scrolledUp: false)
    }
    @Test(arguments: stride(from: 0, through: 160, by: 20).map { CGFloat($0) })
    func aProgrammaticResizeKeepsAReaderScrolledUpInPlace(offset: CGFloat) throws {
        try resizeKeepsTheReadersPlace(live: false, scrolledUp: true, offset: offset)
    }
    /// An animated resize (a pane opening grows the window, the zoom button) counts as a live resize while it runs but
    /// never posts its end: the rows must still end up measured for the final width. The window server only animates
    /// with the display awake, so a sleeping Mac skips it (the drag test below covers the re-measure without it).
    @Test(
        .enabled(
            if: CGDisplayIsAsleep(CGMainDisplayID()) == 0, "the window server doesn't animate while the display sleeps")
    )
    func anAnimatedResizeEndsWithEveryRowMeasured() async throws {
        let harness = Harness()
        let shown = messages(0..<12)
        harness.show(shown)
        let rows = TimelineRow.rows(shown)
        harness.window.setContentSize(NSSize(width: 700, height: 600))
        harness.window.orderFront(nil)
        harness.settle()
        var sawLiveResize = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: harness.table, queue: nil
        ) { _ in
            MainActor.assumeIsolated { if harness.scroll.inLiveResize { sawLiveResize = true } }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            harness.window.orderOut(nil)
        }
        harness.window.setFrame(
            NSRect(origin: harness.window.frame.origin, size: NSSize(width: 380, height: harness.window.frame.height)),
            display: true, animate: true)
        #expect(sawLiveResize, "the animation should count as a live resize")
        func measured(_ index: Int) -> Bool {
            let layout = RowLayout.make(
                rows[index], width: harness.table.bounds.width, own: rows[index].message.sender.id == "me", kind: .space
            )
            return harness.table.rect(ofRow: index).height == layout.height
        }
        await eventually {
            harness.settle()
            return rows.indices.allSatisfy(measured)
        }
        for rowIndex in 0..<rows.count {
            let layout = RowLayout.make(
                rows[rowIndex], width: harness.table.bounds.width, own: rows[rowIndex].message.sender.id == "me",
                kind: .space)
            #expect(
                harness.table.rect(ofRow: rowIndex).height == layout.height,
                "row \(rowIndex): row \(harness.table.rect(ofRow: rowIndex).height), layout \(layout.height) at \(harness.table.bounds.width)"
            )
        }
    }
    /// Dragging a window narrower keeps rows at their old heights until the drag ends; the end re-measures every row
    /// at the final width, even though AppKit still reports the live resize while it posts its end.
    @Test func aDragResizeEndsWithEveryRowMeasuredAtTheFinalWidth() throws {
        let harness = Harness()
        let shown = messages(0..<12)
        let rows = TimelineRow.rows(shown)
        harness.window.setContentSize(NSSize(width: 700, height: 600))
        harness.show(shown)
        harness.coordinator.resizing = true  // as during a drag: rows keep their layouts
        for width in stride(from: 650, through: 330, by: -40) {
            harness.window.setContentSize(NSSize(width: CGFloat(width), height: 600))
            harness.settle()
        }  // a drag's steps
        // Mid-drag, the rows in view are already measured at the new width: none is drawn clipped.
        let visible = harness.table.rows(in: harness.scroll.documentVisibleRect)
        for rowIndex in visible.location..<visible.location + visible.length {
            let layout = RowLayout.make(
                rows[rowIndex], width: harness.table.bounds.width, own: rows[rowIndex].message.sender.id == "me",
                kind: .space)
            #expect(
                harness.table.rect(ofRow: rowIndex).height == layout.height,
                "mid-drag row \(rowIndex): row \(harness.table.rect(ofRow: rowIndex).height), layout \(layout.height)")
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: harness.window)
        harness.settle()
        for rowIndex in 0..<rows.count {
            let layout = RowLayout.make(
                rows[rowIndex], width: harness.table.bounds.width, own: rows[rowIndex].message.sender.id == "me",
                kind: .space)
            #expect(
                harness.table.rect(ofRow: rowIndex).height == layout.height,
                "row \(rowIndex): row \(harness.table.rect(ofRow: rowIndex).height), layout \(layout.height) at \(harness.table.bounds.width)"
            )
        }
    }
    /// Each row is measured once per width: row views take the table's layouts instead of measuring again, and going
    /// back to a recent width (a pane closing again) reuses the layouts made for it.
    @Test func eachRowIsMeasuredOncePerWidth() {
        let tally = MeasureTally()
        RowLayout.$tally.withValue(tally) {
            let harness = Harness()
            harness.show(messages(0..<12))
            for width in [420.0, 800, 420, 800] {
                harness.window.setContentSize(NSSize(width: width, height: 600))
                harness.settle()
            }
        }
        let repeated = Dictionary(grouping: tally.rows, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(repeated.isEmpty, "measured more than once: \(repeated)")
        #expect(
            Set(tally.rows.map { $0.split(separator: "@")[1] }).count == 2,
            "widths measured: \(Set(tally.rows.map { $0.split(separator: "@")[1] }))")
    }
    /// A long history isn't re-measured all at once when a resize ends: the rows nearest the reader are, then the rest
    /// over the next turns of the run loop, while the reader's message stays where it was.
    @Test func aLongHistoryIsRemeasuredNearTheReaderFirst() async throws {
        let harness = Harness()
        let shown = messages(0..<600)
        let rows = TimelineRow.rows(shown)
        harness.show(shown)
        harness.scroll(to: harness.table.bounds.height / 2)
        let first = try #require(
            (harness.table.rows(in: harness.clip).location..<harness.table.numberOfRows).first {
                harness.table.rect(ofRow: $0).minY >= harness.clip.minY
            })
        let id = rows[first].id
        let onScreen = harness.table.rect(ofRow: first).minY - harness.clip.minY
        func checkPlace(_ step: String) {
            let index = harness.coordinator.rows.firstIndex { $0.id == id }!
            #expect(
                abs(harness.table.rect(ofRow: index).minY - harness.clip.minY - onScreen) <= 1,
                "\(step): the reader's message moved")
        }
        func measured(_ rowIndex: Int) -> Bool {
            harness.table.rect(ofRow: rowIndex).height
                == RowLayout.make(
                    rows[rowIndex], width: harness.table.bounds.width, own: rows[rowIndex].message.sender.id == "me",
                    kind: .space
                ).height
        }
        harness.window.setContentSize(NSSize(width: 420, height: 600))
        harness.settle()
        checkPlace("right after the resize")
        let visible = harness.table.rows(in: harness.clip)
        #expect(
            (visible.location..<visible.location + visible.length).allSatisfy(measured),
            "rows in view are measured at once")
        #expect(!rows.indices.allSatisfy(measured), "far rows wait for later turns")
        for _ in 0..<200 where !rows.indices.allSatisfy(measured) {
            try await Task.sleep(for: .milliseconds(10))
            harness.settle()
            checkPlace("while re-measuring")
        }
        #expect(rows.indices.allSatisfy(measured), "every row ends up measured")
        checkPlace("after re-measuring")
    }
}
