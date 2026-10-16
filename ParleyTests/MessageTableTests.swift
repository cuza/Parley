import AppKit
import SwiftUI
import Testing
@testable import Parley

@MainActor struct MessageTableTests {
    private let alex = Person(id: "alex", name: "Alex"), me = Person(id: "me", name: "Me")
    private let lines = ["ok", "What can you do?", String(repeating: "A long message that wraps when the window is narrow. ", count: 5), "Unsupported message"]
    private func messages(_ range: Range<Int>) -> [Message] {
        range.map { i in Message(id: String(format: "m%04d", i), conversationID: "c", sender: i % 3 == 0 ? me : alex,
                                 text: lines[i % lines.count], createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)) }
    }
    @MainActor private final class Harness {
        let coordinator = MessageTable.Coordinator()
        let scroll: NSScrollView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        var atBottom: [Bool] = []
        var nearTop = 0   // requests for older history
        var nearBottom = 0   // a detached window's requests for newer history
        var actions = MessageRowActions()
        var table: NSTableView { scroll.documentView as! NSTableView }
        init() {
            scroll = MessageTable.makeScrollView(coordinator, identifier: "t")
            window.contentView = scroll
        }
        func show(_ messages: [Message], seen: [MessageID: [String]] = [:], scrollRequest: Int = 0, bottomInset: CGFloat = 0,
                  highlighted: MessageID? = nil, detached: Bool = false) {
            coordinator.update(MessageTable(rows: TimelineRow.rows(messages, seen: seen), meID: "me", kind: .space, highlighted: highlighted, actions: actions,
                                            nearTop: { [weak self] in self?.nearTop += 1 }, nearBottom: { [weak self] in self?.nearBottom += 1 },
                                            detached: detached, atBottomChanged: { [weak self] in self?.atBottom.append($0) }, scrollRequest: scrollRequest,
                                            bottomInset: bottomInset))
            settle()
        }
        func settle() { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func scroll(to y: CGFloat) { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView); settle() }
        var visibleTop: CGFloat { scroll.documentVisibleRect.minY }
        var clip: NSRect { scroll.contentView.bounds }
        /// How far above the composer the newest message ends (0 when it rests just above it).
        var gapAboveComposer: CGFloat { clip.maxY - scroll.contentInsets.bottom - table.bounds.height }
    }

    /// Only a message I just sent (still pending) takes a reader who scrolled up to the bottom; a page that happens to end
    /// with an older message of mine (a window meeting the newest messages) leaves them where they are.
    @Test func onlyAJustSentMessagePullsAScrolledReaderDown() throws {
        let h = Harness()
        h.show(messages(0..<100))
        h.scroll(to: 400)
        var page = messages(0..<120)
        page[119] = Message(id: page[119].id, conversationID: "c", sender: me, text: "mine, sent earlier", createdAt: page[119].createdAt)
        h.show(page)
        #expect(abs(h.visibleTop - 400) < 1, "a page ending with my old message: top \(h.visibleTop)")
        let sending = Message(id: "local-1", conversationID: "c", sender: me, text: "just now", createdAt: page[119].createdAt + 60, delivery: .pending)
        h.show(page + [sending])
        #expect(h.clip.maxY >= h.table.bounds.height - 1, "my send shows at the bottom")
    }

    /// A window opened at an old message (a search result, a link): it shows the message, not the window's end;
    /// scrolling near its bottom asks for newer history, and a newer page landing below doesn't pull the reader down.
    @Test func aDetachedWindowPagesDownWithoutFollowingTheBottom() throws {
        let h = Harness()
        h.show(messages(0..<200), highlighted: "m0100", detached: true)
        let row = h.table.rect(ofRow: 100)
        #expect(h.scroll.documentVisibleRect.intersects(row), "the opened message is on screen")
        #expect(h.nearBottom == 0, "far from the window's end")
        h.scroll(to: h.table.bounds.height - h.clip.height)   // the reader scrolls to the window's end
        #expect(h.nearBottom == 1)
        let top = h.visibleTop, height = h.table.bounds.height
        h.show(messages(0..<230), highlighted: "m0100", detached: true)   // the newer page lands below
        #expect(abs(h.visibleTop - top) < 1, "stays where the reader was: top \(top) → \(h.visibleTop), height \(height) → \(h.table.bounds.height)")
        let small = Harness()
        small.show(messages(0..<40), highlighted: "m0020", detached: true)
        small.scroll(to: small.table.bounds.height - small.clip.height)
        let smallTop = small.visibleTop, smallHeight = small.table.bounds.height
        small.show(messages(0..<70), highlighted: "m0020", detached: true)
        #expect(abs(small.visibleTop - smallTop) < 1, "small: top \(smallTop) → \(small.visibleTop), height \(smallHeight) → \(small.table.bounds.height), clip \(small.clip.height)")
        let joined = Harness()
        joined.show(messages(0..<40))
        joined.scroll(to: joined.table.bounds.height - joined.clip.height)
        #expect(joined.nearBottom == 0, "a timeline at the newest messages has nothing newer to ask for")
    }

    /// Hosted by SwiftUI as in the app: a side pane opening beside the timeline narrows it, its rows grow, and the
    /// newest message must still rest just above the composer.
    @Test func openingASidePaneKeepsThePinnedReaderAboveTheComposer() throws {
        let coordinator = MessageTable.Coordinator()
        let rows = TimelineRow.rows(messages(0..<40))
        func content(pane: Bool) -> some View {
            HStack(spacing: 0) {
                MessageTableHost(coordinator: coordinator, table: MessageTable(rows: rows, meID: "me", kind: .space,
                    actions: MessageRowActions(), nearTop: {}, bottomInset: 60))
                if pane { Color.clear.frame(width: 300) }
            }
        }
        let host = NSHostingView(rootView: AnyView(content(pane: false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        func settle() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        settle()
        for pane in [true, false, true] {
            host.rootView = AnyView(content(pane: pane)); settle()
            let scroll = try #require(coordinator.scroll), table = try #require(coordinator.table)
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
        let shown = messages(0..<12), rows = TimelineRow.rows(shown)
        func content(pane: Bool) -> some View {
            HStack(spacing: 0) {
                MessageTableHost(coordinator: coordinator, table: MessageTable(rows: rows, meID: "me", kind: .space,
                    actions: MessageRowActions(), nearTop: {}, bottomInset: 60))
                if pane { Color.clear.frame(width: 321) }
            }
        }
        let host = NSHostingView(rootView: AnyView(content(pane: false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 770, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        func settle() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        settle()
        for pane in [true, false] {
            host.rootView = AnyView(content(pane: pane)); settle()
            let table = try #require(coordinator.table)
            for i in 0..<rows.count {
                let rect = table.rect(ofRow: i)
                let layout = RowLayout.make(rows[i], width: table.bounds.width, own: rows[i].message.sender.id == "me", kind: .space)
                #expect(rect.height == layout.height, "pane \(pane) row \(i): row \(rect.height), layout \(layout.height) at \(table.bounds.width)")
            }
        }
    }
    /// Hosted as in the app: a read receipt arrives for the newest message ("Seen" under it), which makes its row
    /// taller; a reader at the bottom must still see it above the composer.
    @Test func aReceiptOnTheNewestMessageKeepsItAboveTheComposer() throws {
        let coordinator = MessageTable.Coordinator()
        let shown = messages(0..<40), newest = try #require(shown.last)
        func content(seen: Bool) -> some View {
            MessageTableHost(coordinator: coordinator, table: MessageTable(rows: TimelineRow.rows(shown, seen: seen ? [newest.id: ["Alex"]] : [:]),
                meID: "me", kind: .direct, actions: MessageRowActions(), nearTop: {}, bottomInset: 60))
        }
        let host = NSHostingView(rootView: AnyView(content(seen: false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        func settle() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        settle()
        let table = try #require(coordinator.table), scroll = try #require(coordinator.scroll)
        let before = table.rect(ofRow: table.numberOfRows - 1).height
        host.rootView = AnyView(content(seen: true)); settle()
        let rowsEnd = table.rect(ofRow: table.numberOfRows - 1).maxY
        #expect(table.rect(ofRow: table.numberOfRows - 1).height > before, "the receipt adds a line")
        #expect(table.frame.height == rowsEnd, "table \(table.frame.height), rows end at \(rowsEnd)")
        let gap = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom - rowsEnd
        #expect(abs(gap) < 0.5, "the newest message ends \(gap) pt from the composer")
    }
    /// Seen live as a wiggle: a read receipt moving to the newest message re-measured rows with NSTableView's height
    /// animation while the scroll position was already final, so rows slid into place.
    @Test func aReceiptMovingDoesNotAnimateRows() {
        let h = Harness(), shown = messages(0..<40)
        h.show(shown, seen: [shown[36].id: ["Alex"]], bottomInset: 60)
        h.show(shown, seen: [shown[39].id: ["Alex"]], bottomInset: 60)
        func keys(_ v: NSView) -> [String] { (v.layer?.animationKeys() ?? []) + v.subviews.flatMap(keys) }
        let animating = (0..<h.table.numberOfRows).filter { h.table.rowView(atRow: $0, makeIfNecessary: false).map(keys)?.isEmpty == false }
        #expect(animating.isEmpty, "rows animating: \(animating)")
        #expect(abs(h.gapAboveComposer) < 0.5)
    }
    @Test func aShortConversationShowsNoScroller() {
        let h = Harness()
        h.scroll.scrollerStyle = .legacy   // "Show scroll bars: Always", or a mouse attached
        h.show(messages(0..<2)); h.scroll.tile()
        #expect(h.scroll.verticalScroller?.isHidden != false)
        h.show(messages(0..<60)); h.scroll.tile()
        #expect(h.scroll.verticalScroller?.isHidden == false)
    }
    @Test func afterAResizeEveryRowMatchesItsLayoutAndRowViewsFollow() {
        let h = Harness(), shown = messages(0..<12)
        h.show(shown)
        let rows = TimelineRow.rows(shown)
        for width in [800.0, 420, 900, 380] {
            h.window.setContentSize(NSSize(width: width, height: 600)); h.settle()
            for i in 0..<rows.count {
                let rect = h.table.rect(ofRow: i)
                let layout = RowLayout.make(rows[i], width: h.table.bounds.width, own: rows[i].message.sender.id == "me", kind: .space)
                #expect(rect.height == layout.height, "width \(width) row \(i): row \(rect.height), layout \(layout.height)")
                if let view = h.table.rowView(atRow: i, makeIfNecessary: false) {
                    #expect(view.frame == rect, "width \(width) row \(i): view \(view.frame), row \(rect)")
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
        let host = NSHostingView(rootView: MessageTableHost(coordinator: coordinator, table: MessageTable(rows: rows, meID: "me", kind: .space,
            actions: MessageRowActions(), nearTop: {}, bottomInset: 60)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        func settle() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        settle()
        let scroll = try #require(coordinator.scroll), table = try #require(coordinator.table)
        func clip() -> NSRect { scroll.contentView.bounds }
        if scrolledUp { scroll.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.height / 2 + offset)); scroll.reflectScrolledClipView(scroll.contentView); settle() }
        // The first row wholly in view (the composer covers the bottom), and how far below the top of the view it is.
        let visible = table.rows(in: clip())
        let anchor = try #require((visible.location..<visible.location + visible.length).first { table.rect(ofRow: $0).minY >= clip().minY })
        let id = rows[anchor].id, onScreen = table.rect(ofRow: anchor).minY - clip().minY
        func check(_ step: String) {
            func keys(_ v: NSView) -> [String] { (v.layer?.animationKeys() ?? []) + v.subviews.flatMap(keys) }
            let animating = (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: false).map(keys)?.isEmpty == false }
            #expect(animating.isEmpty, "offset \(offset) \(step): rows animating into place: \(animating)")
            let misplaced = (0..<table.numberOfRows).filter { i in table.rowView(atRow: i, makeIfNecessary: false).map { $0.frame != table.rect(ofRow: i) } ?? false }
            #expect(misplaced.isEmpty, "\(step): row views away from their rows: \(misplaced)")
            if scrolledUp {
                let index = coordinator.rows.firstIndex { $0.id == id }!
                let y = table.rect(ofRow: index).minY - clip().minY
                #expect(abs(y - onScreen) <= 1, "offset \(offset) \(step): the reader's message moved from \(onScreen) to \(y) pt below the top")
            } else {
                let gap = clip().maxY - scroll.contentInsets.bottom - table.rect(ofRow: table.numberOfRows - 1).maxY
                #expect(abs(gap) <= 1, "\(step): the newest message ends \(gap) pt from the composer")
            }
        }
        if live { coordinator.resizing = true }   // as during a drag (AppKit's `inLiveResize` can't be faked here)
        for width in Array(stride(from: 780, through: 400, by: -20)) + Array(stride(from: 420, through: 900, by: 20)) {
            window.setContentSize(NSSize(width: CGFloat(width), height: 600)); settle()
            check("width \(width)")
        }
        if live { NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window); settle() }
        check("after the resize")
    }
    @Test func aDragResizeKeepsTheNewestMessageAboveTheComposer() throws { try resizeKeepsTheReadersPlace(live: true, scrolledUp: false) }
    /// Offsets across a few rows, so that the row cut off at the top is sometimes a long one that re-wraps.
    @Test(arguments: stride(from: 0, through: 160, by: 20).map { CGFloat($0) })
    func aDragResizeKeepsAReaderScrolledUpInPlace(offset: CGFloat) throws { try resizeKeepsTheReadersPlace(live: true, scrolledUp: true, offset: offset) }
    @Test func aProgrammaticResizeKeepsTheNewestMessageAboveTheComposer() throws { try resizeKeepsTheReadersPlace(live: false, scrolledUp: false) }
    @Test(arguments: stride(from: 0, through: 160, by: 20).map { CGFloat($0) })
    func aProgrammaticResizeKeepsAReaderScrolledUpInPlace(offset: CGFloat) throws { try resizeKeepsTheReadersPlace(live: false, scrolledUp: true, offset: offset) }
    /// An animated resize (a pane opening grows the window, the zoom button) counts as a live resize while it runs but
    /// never posts its end: the rows must still end up measured for the final width. The window server only animates
    /// with the display awake, so a sleeping Mac skips it (the drag test below covers the re-measure without it).
    @Test(.enabled(if: CGDisplayIsAsleep(CGMainDisplayID()) == 0, "the window server doesn't animate while the display sleeps"))
    func anAnimatedResizeEndsWithEveryRowMeasured() async throws {
        let h = Harness(), shown = messages(0..<12)
        h.show(shown)
        let rows = TimelineRow.rows(shown)
        h.window.setContentSize(NSSize(width: 700, height: 600)); h.window.orderFront(nil); h.settle()
        var sawLiveResize = false
        let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: h.table, queue: nil) { _ in
            MainActor.assumeIsolated { if h.scroll.inLiveResize { sawLiveResize = true } }
        }
        defer { NotificationCenter.default.removeObserver(observer); h.window.orderOut(nil) }
        h.window.setFrame(NSRect(origin: h.window.frame.origin, size: NSSize(width: 380, height: h.window.frame.height)), display: true, animate: true)
        #expect(sawLiveResize, "the animation should count as a live resize")
        try await Task.sleep(for: .milliseconds(600)); h.settle()
        for i in 0..<rows.count {
            let layout = RowLayout.make(rows[i], width: h.table.bounds.width, own: rows[i].message.sender.id == "me", kind: .space)
            #expect(h.table.rect(ofRow: i).height == layout.height, "row \(i): row \(h.table.rect(ofRow: i).height), layout \(layout.height) at \(h.table.bounds.width)")
        }
    }
    /// Dragging a window narrower keeps rows at their old heights until the drag ends; the end re-measures every row
    /// at the final width, even though AppKit still reports the live resize while it posts its end.
    @Test func aDragResizeEndsWithEveryRowMeasuredAtTheFinalWidth() throws {
        let h = Harness(), shown = messages(0..<12), rows = TimelineRow.rows(shown)
        h.window.setContentSize(NSSize(width: 700, height: 600)); h.show(shown)
        h.coordinator.resizing = true   // as during a drag: rows keep their layouts
        for width in stride(from: 650, through: 330, by: -40) { h.window.setContentSize(NSSize(width: CGFloat(width), height: 600)); h.settle() }   // a drag's steps
        // Mid-drag, the rows in view are already measured at the new width: none is drawn clipped.
        let visible = h.table.rows(in: h.scroll.documentVisibleRect)
        for i in visible.location..<visible.location + visible.length {
            let layout = RowLayout.make(rows[i], width: h.table.bounds.width, own: rows[i].message.sender.id == "me", kind: .space)
            #expect(h.table.rect(ofRow: i).height == layout.height, "mid-drag row \(i): row \(h.table.rect(ofRow: i).height), layout \(layout.height)")
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: h.window); h.settle()
        for i in 0..<rows.count {
            let layout = RowLayout.make(rows[i], width: h.table.bounds.width, own: rows[i].message.sender.id == "me", kind: .space)
            #expect(h.table.rect(ofRow: i).height == layout.height, "row \(i): row \(h.table.rect(ofRow: i).height), layout \(layout.height) at \(h.table.bounds.width)")
        }
    }
    /// Each row is measured once per width: row views take the table's layouts instead of measuring again, and going
    /// back to a recent width (a pane closing again) reuses the layouts made for it.
    @Test func eachRowIsMeasuredOncePerWidth() {
        let tally = MeasureTally()
        RowLayout.$tally.withValue(tally) {
            let h = Harness()
            h.show(messages(0..<12))
            for width in [420.0, 800, 420, 800] { h.window.setContentSize(NSSize(width: width, height: 600)); h.settle() }
        }
        let repeated = Dictionary(grouping: tally.rows, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(repeated.isEmpty, "measured more than once: \(repeated)")
        #expect(Set(tally.rows.map { $0.split(separator: "@")[1] }).count == 2, "widths measured: \(Set(tally.rows.map { $0.split(separator: "@")[1] }))")
    }
    /// A long history isn't re-measured all at once when a resize ends: the rows nearest the reader are, then the rest
    /// over the next turns of the run loop, while the reader's message stays where it was.
    @Test func aLongHistoryIsRemeasuredNearTheReaderFirst() async throws {
        let h = Harness(), shown = messages(0..<600), rows = TimelineRow.rows(shown)
        h.show(shown)
        h.scroll(to: h.table.bounds.height / 2)
        let first = try #require((h.table.rows(in: h.clip).location..<h.table.numberOfRows).first { h.table.rect(ofRow: $0).minY >= h.clip.minY })
        let id = rows[first].id, onScreen = h.table.rect(ofRow: first).minY - h.clip.minY
        func checkPlace(_ step: String) {
            let index = h.coordinator.rows.firstIndex { $0.id == id }!
            #expect(abs(h.table.rect(ofRow: index).minY - h.clip.minY - onScreen) <= 1, "\(step): the reader's message moved")
        }
        func measured(_ i: Int) -> Bool {
            h.table.rect(ofRow: i).height == RowLayout.make(rows[i], width: h.table.bounds.width, own: rows[i].message.sender.id == "me", kind: .space).height
        }
        h.window.setContentSize(NSSize(width: 420, height: 600)); h.settle()
        checkPlace("right after the resize")
        let visible = h.table.rows(in: h.clip)
        #expect((visible.location..<visible.location + visible.length).allSatisfy(measured), "rows in view are measured at once")
        #expect(!rows.indices.allSatisfy(measured), "far rows wait for later turns")
        for _ in 0..<200 where !rows.indices.allSatisfy(measured) {
            try await Task.sleep(for: .milliseconds(10)); h.settle()
            checkPlace("while re-measuring")
        }
        #expect(rows.indices.allSatisfy(measured), "every row ends up measured")
        checkPlace("after re-measuring")
    }
    @Test func olderPagesInsertAboveWithoutMovingTheReader() {
        let h = Harness()
        h.show(messages(50..<100))
        h.scroll(to: 400)
        let row = h.table.rows(in: h.scroll.documentVisibleRect).location
        let id = h.coordinator.rows[row].id, offset = h.table.rect(ofRow: row).minY - h.visibleTop
        h.show(messages(0..<100))
        let index = try! #require(h.coordinator.rows.firstIndex { $0.id == id })
        #expect(index == row + 50)
        #expect(abs(h.table.rect(ofRow: index).minY - h.visibleTop - offset) < 0.5)
    }
    @Test func aMessageOfPicturesAloneDrawsNoBubbleAndATimePillOverThePicture() throws {
        let h = Harness()
        var shown = messages(0..<2)
        let image = Attachment(name: "a.png", kind: .image, width: 1200, height: 800)
        shown.append(Message(id: "m0100", conversationID: "c", sender: me, text: "", createdAt: Date(timeIntervalSince1970: 1_700_009_000), attachments: [image]))
        shown.append(Message(id: "m0101", conversationID: "c", sender: alex, text: "", createdAt: Date(timeIntervalSince1970: 1_700_009_100), attachments: [image]))
        h.show(shown)
        for id in ["m0100", "m0101"] {
            let index = try #require(h.coordinator.rows.firstIndex { $0.message.id == id })
            let view = try #require(h.table.rowView(atRow: index, makeIfNecessary: false) as? MessageRowView)
            let layout = try #require(view.rowLayout)
            #expect(view.bubbleView.isHidden && layout.mediaOnly)
            let picture = view.attachmentViews[0].frame
            #expect(picture == layout.attachments[0] && picture.size == RowLayout.mediaSize(image, caption: false, room: .greatestFiniteMagnitude))
            #expect(view.timeLabel.frame == layout.time && picture.contains(view.timeLabel.frame))
            #expect(view.timeLabel.background == BubblePalette.mediaPill && view.timeLabel.frame.maxX > picture.maxX - 20)
        }
        let text = try #require(h.table.rowView(atRow: 0, makeIfNecessary: false) as? MessageRowView)
        #expect(!text.bubbleView.isHidden)
    }
    @Test func aPictureFillsTheBubbleOfAQuoteOrCaption() throws {
        let h = Harness()
        var shown = messages(0..<2)
        let image = Attachment(name: "a.png", kind: .image, width: 1200, height: 800)
        let at = { Date(timeIntervalSince1970: 1_700_009_000 + $0) }
        shown.append(Message(id: "m0102", conversationID: "c", sender: alex, text: "", createdAt: at(200), attachments: [image], quote: QuotedMessage(sender: "Sam", text: "hi")))
        shown.append(Message(id: "m0103", conversationID: "c", sender: me, text: "a caption", createdAt: at(300), attachments: [image]))
        h.show(shown)
        for id in ["m0102"] {
            let index = try #require(h.coordinator.rows.firstIndex { $0.message.id == id })
            let view = try #require(h.table.rowView(atRow: index, makeIfNecessary: true) as? MessageRowView)
            let layout = try #require(view.rowLayout)
            let picture = view.attachmentViews[0].frame, bubble = layout.bubble
            #expect(!view.bubbleView.isHidden && picture == layout.attachments[0])
            #expect(picture.minX == bubble.minX + 1 && picture.maxX == bubble.maxX - 1 && picture.maxY == bubble.maxY - 1)   // a 1 pt edge of bubble
            #expect(view.bubbleView.frame.height == bubble.height && view.bubbleView.frame.maxX >= bubble.maxX)
            #expect(view.timeLabel.frame == layout.time && picture.contains(view.timeLabel.frame))
            #expect(view.timeLabel.background == BubblePalette.mediaPill && view.timeLabel.frame.maxX == picture.maxX - RowLayout.mediaPillMargin.width)
            // Its large corners where it meets the bubble's, small ones under the quote; the tail beside it on a run's last.
            #expect(view.attachmentViews[0].rootView.corners == layout.attachmentCorners[0] && layout.attachmentCorners[0] == [.bottomLeft, .bottomRight])
            #expect(layout.tail == view.bubbleView.tail)
        }
        let text = try #require(h.table.rowView(atRow: 0, makeIfNecessary: true) as? MessageRowView)
        #expect(!text.bubbleView.isHidden)
    }
    @Test func ownMessagesRealignWhenTheUserIsKnown() {
        let h = Harness()
        let shown = messages(0..<6)
        h.coordinator.update(MessageTable(rows: TimelineRow.rows(shown), meID: "", kind: .space, actions: MessageRowActions(), nearTop: {}))
        h.settle()
        h.show(shown)   // the signed-in user arrives: meID "me"
        let mine = try! #require(h.coordinator.rows.firstIndex { $0.message.sender.id == "me" })
        let view = try! #require(h.table.rowView(atRow: mine, makeIfNecessary: false) as? MessageRowView)
        #expect(view.rowLayout?.bubble.maxX ?? 0 > h.table.bounds.width / 2, "own bubble should be right-aligned")
    }
    @Test func rowsArrivingBeforeTheTableHasAWidthStillOpenAtTheNewest() {
        let coordinator = MessageTable.Coordinator()
        let scroll = MessageTable.makeScrollView(coordinator, identifier: "t")   // not in a window yet: no width
        coordinator.update(MessageTable(rows: TimelineRow.rows(messages(0..<40)), meID: "me", kind: .space, actions: MessageRowActions(), nearTop: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let table = scroll.documentView as! NSTableView
        #expect(scroll.documentVisibleRect.maxY >= table.bounds.height - 1, "visible \(scroll.documentVisibleRect), table \(table.bounds.height)")
    }
    /// Seen live: a conversation opened with its newest rows behind the floating composer. Rows that arrive before the
    /// table has a width are measured later and grow; the reader must still end just above the composer.
    @Test func rowsMeasuredAfterArrivingStillEndAboveTheComposer() {
        let coordinator = MessageTable.Coordinator()
        let scroll = MessageTable.makeScrollView(coordinator, identifier: "t")
        coordinator.update(MessageTable(rows: TimelineRow.rows(messages(0..<40)), meID: "me", kind: .space, actions: MessageRowActions(),
                                        nearTop: {}, bottomInset: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let table = scroll.documentView as! NSTableView
        let gap = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom - table.bounds.height
        #expect(abs(gap) < 0.5, "newest message ends \(gap) pt from the composer; clip \(scroll.contentView.bounds), table \(table.bounds.height)")
    }
    @Test func aTransientNarrowLayoutDoesNotUnpinTheBottom() {
        // SwiftUI briefly lays the timeline out tiny (130 x 40 pt) while a window first appears.
        let h = Harness()
        h.show(messages(0..<16))
        h.window.setContentSize(NSSize(width: 130, height: 40)); h.settle()
        h.window.setContentSize(NSSize(width: 800, height: 600)); h.settle()
        #expect(h.scroll.documentVisibleRect.maxY >= h.table.bounds.height - 1, "visible \(h.scroll.documentVisibleRect), table \(h.table.bounds.height)")
    }
    @Test func aNewMessageKeepsAReaderAtTheBottomThere() {
        let h = Harness()
        h.show(messages(0..<40))
        #expect(h.scroll.documentVisibleRect.maxY >= h.table.bounds.height - 1)
        h.show(messages(0..<41))
        #expect(h.scroll.documentVisibleRect.maxY >= h.table.bounds.height - 1)
    }
    @Test func reportsLeavingAndReturningToTheNewestMessages() async {
        let h = Harness()
        h.show(messages(0..<80))
        h.scroll(to: 0)
        await Task.yield(); try? await Task.sleep(for: .milliseconds(50))   // reported after the current update
        #expect(h.atBottom.last == false)
        h.show(messages(0..<80), scrollRequest: 1)   // the scroll-to-bottom button
        try? await Task.sleep(for: .milliseconds(400))
        h.settle()
        #expect(h.atBottom.last == true)
    }

    // The composer floats over the timeline: the table gets a bottom inset of the composer's height.
    @Test func aPinnedReaderStaysJustAboveTheComposerAsItGrowsAndShrinks() {
        let h = Harness()
        h.show(messages(0..<80))
        for inset: CGFloat in [120, 200, 60, 0, 90] {
            h.show(messages(0..<80), bottomInset: inset)
            #expect(h.scroll.contentInsets.bottom == inset)
            #expect(abs(h.gapAboveComposer) < 0.5, "inset \(inset): newest message ends \(h.gapAboveComposer) pt from the composer")
        }
        h.show(messages(0..<81), bottomInset: 90)   // a new message while pinned
        #expect(abs(h.gapAboveComposer) < 0.5)
    }
    @Test func aShortConversationKeepsItsFirstMessageInView() {
        let h = Harness()
        h.show(messages(0..<3), bottomInset: 200)
        #expect(h.table.rect(ofRow: 0).minY >= h.clip.minY, "first row \(h.table.rect(ofRow: 0)), clip \(h.clip), table \(h.table.bounds)")
    }
    @Test func theComposerResizingDoesNotMoveAReaderScrolledUp() {
        let h = Harness()
        h.show(messages(0..<80), bottomInset: 60)
        h.scroll(to: 400)
        let top = h.clip.minY
        h.show(messages(0..<80), bottomInset: 180)
        #expect(h.clip.minY == top)
        h.show(messages(0..<80), bottomInset: 40)
        #expect(h.clip.minY == top)
    }
    @Test func scrollingTheNewestMessageBehindTheComposerUnpins() {
        let h = Harness()
        h.show(messages(0..<80), bottomInset: 200)
        h.scroll(to: h.clip.minY - 100)   // the newest message is now under the composer
        h.show(messages(0..<81), bottomInset: 200)
        #expect(h.gapAboveComposer < -50, "a reader who scrolled up is not pulled down")
        h.scroll(to: h.table.bounds.height + 200 - h.clip.height - 10)   // back within reach of the bottom
        h.show(messages(0..<82), bottomInset: 200)
        #expect(abs(h.gapAboveComposer) < 0.5)
    }
    @Test func atBottomCountsOnlyThePartOfTheViewAboveTheComposer() async {
        let h = Harness()
        h.show(messages(0..<80), bottomInset: 200)
        let visible = h.clip.height - 200
        // Within one full view of the newest message, but more than one uncovered view away from it.
        h.scroll(to: h.table.bounds.height - 2 * h.clip.height + 200)
        #expect(h.clip.maxY - 200 < h.table.bounds.height - visible)
        await Task.yield(); try? await Task.sleep(for: .milliseconds(50))
        #expect(h.atBottom.last == false)
        h.show(messages(0..<80), scrollRequest: 1, bottomInset: 200)
        try? await Task.sleep(for: .milliseconds(400))
        h.settle()
        #expect(h.atBottom.last == true)
        #expect(abs(h.gapAboveComposer) < 0.5, "scroll to bottom rests the newest message just above the composer")
    }

    /// Older history is asked for three screens before the top, and again as each page lands while the reader is
    /// still there, so a fast scroll keeps paging; a page that adds nothing asks no more.
    @Test func olderPagesKeepLoadingWhileTheReaderIsNearTheTop() {
        let h = Harness()
        h.show(messages(100..<300))
        #expect(h.nearTop == 0, "at the newest message, far from the top")
        h.scroll(to: MessageTable.Coordinator.topZone(visibleHeight: h.clip.height) + 400)
        #expect(h.nearTop == 0)
        h.scroll(to: 0)
        #expect(h.nearTop == 1, "entering the zone")
        h.scroll(to: 50)
        #expect(h.nearTop == 1, "scrolling within the zone asks nothing more")
        h.show(messages(95..<300))   // a page lands; the reader is still near the top
        #expect(h.visibleTop < MessageTable.Coordinator.topZone(visibleHeight: h.clip.height))
        #expect(h.nearTop == 2, "the next page is asked for at once")
        h.show(messages(95..<300))   // nothing new
        h.scroll(to: 0)
        #expect(h.nearTop == 2, "a page that adds no rows does not loop")
        h.scroll(to: h.table.bounds.height); h.scroll(to: 0)
        #expect(h.nearTop == 3, "re-entering the zone asks again")
    }
    /// Scrolling reuses row views, as a table should: the views ever made stay near a screenful, however long the history.
    @Test func scrollingALongHistoryReusesRowViews() {
        let h = Harness()
        h.show(messages(0..<600))
        var made = Set<ObjectIdentifier>()
        func note() { for i in 0..<h.table.numberOfRows { if let view = h.table.rowView(atRow: i, makeIfNecessary: false) { made.insert(ObjectIdentifier(view)) } } }
        var y: CGFloat = h.table.bounds.height
        while y > 0 { y -= 300; h.scroll(to: max(0, y)); note() }
        let screenful = Int(h.clip.height / 40) + 10
        #expect(made.count < screenful * 3, "\(made.count) row views for \(h.table.numberOfRows) rows")
    }
    /// A page's pictures are fetched and decoded into the cache as it lands, before their rows scroll into view.
    /// The keyboard reaches a message, as in Mail: ↑ and ↓ move between them, Return replies in its thread, E edits one of
    /// mine, Delete asks to delete one of mine, and Esc leaves the list.
    @Test func theKeyboardSelectsAndActsOnMessages() throws {
        var calls: [String] = []
        let h = Harness()
        h.actions.openThread = { calls.append("thread \($0.id)") }
        h.actions.quote = { calls.append("quote \($0.id)") }
        h.actions.edit = { calls.append("edit \($0.id)") }
        h.actions.delete = { calls.append("delete \($0.id)") }
        h.show(messages(0..<6))   // every third is mine: m0000, m0003
        let table = try #require(h.table as? TimelineTableView)
        func press(_ keyCode: UInt16, _ characters: String) throws {
            table.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
                                                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)))
        }
        h.window.makeFirstResponder(table)
        table.selectLast()
        #expect(table.selectedRow == 5)
        try press(126, "\u{F700}")   // ↑
        #expect(table.selectedRow == 4)
        try press(36, "\r")           // Return: replies in m0004's thread
        try press(14, "e")            // not mine: nothing
        try press(126, "\u{F700}")
        try press(51, "\u{7F}")       // m0003 is mine: Delete asks first (the action does)
        try press(14, "e")            // edits it, in the composer
        #expect(calls == ["thread m0004", "delete m0003", "edit m0003"])
        #expect(table.selectedRow == -1)   // the edit took the keyboard back to the composer
        table.selectLast()
        try press(53, "\u{1B}")       // Esc leaves the list
        #expect(table.selectedRow == -1)
    }
    @Test func aLandedPageWarmsItsThumbnails() async throws {
        // The pictures' URLs are new, so the shared cache has none of them. Clearing it would also wipe other tests' entries.
        let h = Harness(), fake = FakeBackend()
        var fetched = 0
        h.actions.loadAttachment = { attachment, thumbnail in fetched += 1; return try await fake.attachmentData(attachment, thumbnail: thumbnail) }
        let pictures = (0..<6).map { Attachment(name: "p\($0).png", contentType: "image/png", kind: .image, url: URL(string: "https://example.com/warm-\(UUID())"), width: 1200, height: 900) }
        var older = messages(0..<6)
        for i in older.indices { older[i].attachments = [pictures[i]] }
        h.show(messages(6..<40))
        h.show(older + messages(6..<40))
        // The shared cache is the app's: tests running alongside fill it, and with its memory budget it may let one of
        // these go again. What this test owns is the fetch (each picture once) and the decode (at display size).
        await eventually(timeout: .seconds(5)) { fetched == pictures.count && pictures.allSatisfy { ImageCache.cached($0) != nil } }
        #expect(fetched == pictures.count, "rows on screen and the prefetch share one fetch per picture")
        let kept = pictures.filter { ImageCache.cached($0) != nil }
        for picture in pictures {
            guard let image = ImageCache.cached(picture) else { continue }
            #expect(max(image.size.width, image.size.height) <= CGFloat(picture.displayPixels), "decoded at display size")
        }
        #expect(!kept.isEmpty, "the warmed pictures went into the cache")
    }
}

/// `ImageCache`: pictures decode at the size they are drawn, GIFs keep their frames, and a cached one is on screen at once.
@MainActor struct ImageCacheTests {
    @Test func aStillImageIsDownsampledAndAGIFKeepsItsFrames() async throws {
        let png = try await FakeBackend().attachmentData(Attachment(name: "big.png", kind: .image, width: 2000, height: 1000), thumbnail: true)
        let image = try #require(ImageCache.decode(png, maxPixels: 500))
        #expect(image.size == NSSize(width: 500, height: 250))
        let gif = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(gif, "com.compuserve.gif" as CFString, 3, nil))
        let frame = try #require(NSBitmapImageRep(data: png)?.cgImage)
        for _ in 0..<3 { CGImageDestinationAddImage(destination, frame, nil) }
        #expect(CGImageDestinationFinalize(destination))
        let animated = try #require(ImageCache.decode(gif as Data, maxPixels: 100))
        let rep = try #require(animated.representations.first as? NSBitmapImageRep)
        #expect(rep.value(forProperty: .frameCount) as? Int == 3)
    }
    @Test func aCachedPictureShowsOnTheFirstFrame() throws {
        let picture = Attachment(name: "seen.png", kind: .image, url: URL(string: "https://example.com/seen-\(UUID())"), width: 320, height: 240)
        let seeded = NSImage(size: NSSize(width: 32, height: 24))
        ImageCache.shared.setObject(seeded, forKey: ImageCache.key(picture) as NSString)
        let host = NSHostingView(rootView: AttachmentView(attachment: picture, load: { _, _ in throw URLError(.notConnectedToInternet) }))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        func images(_ view: NSView) -> [NSImageView] { ((view as? NSImageView).map { [$0] } ?? []) + view.subviews.flatMap(images) }
        #expect(images(host).contains { $0.image === seeded })
    }
}

/// `MessageTable` with a coordinator the test holds, so it can look at the table SwiftUI lays out.
private struct MessageTableHost: NSViewRepresentable {
    let coordinator: MessageTable.Coordinator
    let table: MessageTable
    func makeNSView(context: Context) -> NSScrollView { MessageTable.makeScrollView(coordinator, identifier: "t") }
    func updateNSView(_ scroll: NSScrollView, context: Context) { coordinator.update(table) }
}

/// The whole window as the app shows it: opening a thread beside a conversation narrows the timeline, and its rows
/// must follow (the README's thread screenshot showed bubbles clipped to their old height).
@MainActor struct TimelineInWindowTests {
    @Test func openingAThreadRemeasuresTheConversationsRows() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let host = NSHostingView(rootView: ChatView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        func settle() async { for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(100)) } }
        await settle()
        let threaded = try #require(store.messages.first { $0.conversationID == store.selectedID && $0.replyCount > 0 })
        await store.openThread(threaded)
        await settle()
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        let timeline = try #require(tables(host).filter { $0.numberOfRows > 0 }.max { $0.bounds.width < $1.bounds.width })
        for i in 0..<timeline.numberOfRows {
            guard let view = timeline.rowView(atRow: i, makeIfNecessary: false) as? MessageRowView, let layout = view.rowLayout else { continue }
            #expect(timeline.rect(ofRow: i).height == layout.height, "row \(i): row \(timeline.rect(ofRow: i).height), layout \(layout.height) at \(timeline.bounds.width)")
        }
    }
}

/// A conversation with no messages yet: the composer still spans the timeline (it shrank to the placeholder's width).
@MainActor struct EmptyConversationTests {
    @Test func theComposerSpansAnEmptyConversation() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let empty = Conversation(id: "dm/nobody-yet", name: "New", kind: .direct, members: [])
        let host = NSHostingView(rootView: TimelineView(store: store, conversation: empty).frame(width: 800, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(editors) }
        let composer = try #require(editors(host).first)
        #expect(composer.convert(composer.bounds, to: host).width > 500, "composer is \(composer.bounds.width) wide in an 800 pt timeline")
    }
}
