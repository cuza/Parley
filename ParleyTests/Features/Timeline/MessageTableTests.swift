import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct MessageTableTests {
    private typealias Harness = MessageTableHarness
    private let alex = MessageTableHarness.alex, me = MessageTableHarness.me
    private func messages(_ range: Range<Int>) -> [Message] { MessageTableHarness.messages(range) }

    /// Only a message I just sent (still pending) takes a reader who scrolled up to the bottom; a page that happens to end
    /// with an older message of mine (a window meeting the newest messages) leaves them where they are.
    @Test func onlyAJustSentMessagePullsAScrolledReaderDown() throws {
        let harness = Harness()
        harness.show(messages(0..<100))
        harness.scroll(to: 400)
        var page = messages(0..<120)
        page[119] = .fixture("mine, sent earlier", id: page[119].id, from: me, at: page[119].createdAt)
        harness.show(page)
        #expect(abs(harness.visibleTop - 400) < 1, "a page ending with my old message: top \(harness.visibleTop)")
        let sending = Message.fixture(
            "just now", id: "local-1", from: me, at: page[119].createdAt + 60, delivery: .pending)
        harness.show(page + [sending])
        #expect(harness.clip.maxY >= harness.table.bounds.height - 1, "my send shows at the bottom")
    }

    /// A window opened at an old message (a search result, a link): it shows the message, not the window's end;
    /// scrolling near its bottom asks for newer history, and a newer page landing below doesn't pull the reader down.
    @Test func aDetachedWindowPagesDownWithoutFollowingTheBottom() throws {
        let harness = Harness()
        harness.show(messages(0..<200), highlighted: "m0100", detached: true)
        let row = harness.table.rect(ofRow: 100)
        #expect(harness.scroll.documentVisibleRect.intersects(row), "the opened message is on screen")
        #expect(harness.nearBottom == 0, "far from the window's end")
        harness.scroll(to: harness.table.bounds.height - harness.clip.height)  // the reader scrolls to the window's end
        #expect(harness.nearBottom == 1)
        let top = harness.visibleTop
        let height = harness.table.bounds.height
        harness.show(messages(0..<230), highlighted: "m0100", detached: true)  // the newer page lands below
        #expect(
            abs(harness.visibleTop - top) < 1,
            "stays where the reader was: top \(top) → \(harness.visibleTop), height \(height) → \(harness.table.bounds.height)"
        )
        let small = Harness()
        small.show(messages(0..<40), highlighted: "m0020", detached: true)
        small.scroll(to: small.table.bounds.height - small.clip.height)
        let smallTop = small.visibleTop
        let smallHeight = small.table.bounds.height
        small.show(messages(0..<70), highlighted: "m0020", detached: true)
        #expect(
            abs(small.visibleTop - smallTop) < 1,
            "small: top \(smallTop) → \(small.visibleTop), height \(smallHeight) → \(small.table.bounds.height), clip \(small.clip.height)"
        )
        let joined = Harness()
        joined.show(messages(0..<40))
        joined.scroll(to: joined.table.bounds.height - joined.clip.height)
        #expect(joined.nearBottom == 0, "a timeline at the newest messages has nothing newer to ask for")
    }

    @Test func aShortConversationShowsNoScroller() {
        let harness = Harness()
        harness.scroll.scrollerStyle = .legacy  // "Show scroll bars: Always", or a mouse attached
        harness.show(messages(0..<2))
        harness.scroll.tile()
        #expect(harness.scroll.verticalScroller?.isHidden != false)
        harness.show(messages(0..<60))
        harness.scroll.tile()
        #expect(harness.scroll.verticalScroller?.isHidden == false)
    }
    @Test func olderPagesInsertAboveWithoutMovingTheReader() throws {
        let harness = Harness()
        harness.show(messages(50..<100))
        harness.scroll(to: 400)
        let row = harness.table.rows(in: harness.scroll.documentVisibleRect).location
        let id = harness.coordinator.rows[row].id
        let offset = harness.table.rect(ofRow: row).minY - harness.visibleTop
        harness.show(messages(0..<100))
        let index = try #require(harness.coordinator.rows.firstIndex { $0.id == id })
        #expect(index == row + 50)
        #expect(abs(harness.table.rect(ofRow: index).minY - harness.visibleTop - offset) < 0.5)
    }
    @Test func aMessageOfPicturesAloneDrawsNoBubbleAndATimePillOverThePicture() throws {
        let harness = Harness()
        var shown = messages(0..<2)
        let image = Attachment.fixture(.image, width: 1200, height: 800)
        shown.append(
            .fixture("", id: "m0100", from: me, at: Date(timeIntervalSince1970: 1_700_009_000), attachments: [image]))
        shown.append(
            .fixture("", id: "m0101", from: alex, at: Date(timeIntervalSince1970: 1_700_009_100), attachments: [image]))
        harness.show(shown)
        for id: MessageID in ["m0100", "m0101"] {
            let index = try #require(harness.coordinator.rows.firstIndex { $0.message.id == id })
            let view = try #require(harness.table.rowView(atRow: index, makeIfNecessary: false) as? MessageRowView)
            let layout = try #require(view.rowLayout)
            #expect(view.bubbleView.isHidden && layout.mediaOnly)
            let picture = view.attachmentViews[0].frame
            #expect(
                picture == layout.attachments[0]
                    && picture.size == RowLayout.mediaSize(image, caption: false, room: .greatestFiniteMagnitude))
            #expect(view.timeLabel.frame == layout.time && picture.contains(view.timeLabel.frame))
            #expect(
                view.timeLabel.background == BubblePalette.mediaPill && view.timeLabel.frame.maxX > picture.maxX - 20)
        }
        let text = try #require(harness.table.rowView(atRow: 0, makeIfNecessary: false) as? MessageRowView)
        #expect(!text.bubbleView.isHidden)
    }
    @Test func aPictureFillsTheBubbleOfAQuoteOrCaption() throws {
        let harness = Harness()
        var shown = messages(0..<2)
        let image = Attachment.fixture(.image, width: 1200, height: 800)
        let at = { Date(timeIntervalSince1970: 1_700_009_000 + $0) }
        shown.append(
            .fixture("", id: "m0102", from: alex, at: at(200), attachments: [image]) {
                $0.quote = QuotedMessage(sender: "Sam", text: "hi")
            })
        shown.append(.fixture("a caption", id: "m0103", from: me, at: at(300), attachments: [image]))
        harness.show(shown)
        for id: MessageID in ["m0102"] {
            let index = try #require(harness.coordinator.rows.firstIndex { $0.message.id == id })
            let view = try #require(harness.table.rowView(atRow: index, makeIfNecessary: true) as? MessageRowView)
            let layout = try #require(view.rowLayout)
            let picture = view.attachmentViews[0].frame
            let bubble = layout.bubble
            #expect(!view.bubbleView.isHidden && picture == layout.attachments[0])
            #expect(
                picture.minX == bubble.minX + 1 && picture.maxX == bubble.maxX - 1 && picture.maxY == bubble.maxY - 1)  // a 1 pt edge of bubble
            #expect(view.bubbleView.frame.height == bubble.height && view.bubbleView.frame.maxX >= bubble.maxX)
            #expect(view.timeLabel.frame == layout.time && picture.contains(view.timeLabel.frame))
            #expect(
                view.timeLabel.background == BubblePalette.mediaPill
                    && view.timeLabel.frame.maxX == picture.maxX - RowLayout.mediaPillMargin.width)
            // Its large corners where it meets the bubble's, small ones under the quote; the tail beside it on a run's last.
            #expect(
                view.attachmentViews[0].rootView.corners == layout.attachmentCorners[0]
                    && layout.attachmentCorners[0] == [.bottomLeft, .bottomRight])
            #expect(layout.tail == view.bubbleView.tail)
        }
        let text = try #require(harness.table.rowView(atRow: 0, makeIfNecessary: true) as? MessageRowView)
        #expect(!text.bubbleView.isHidden)
    }
    @Test func ownMessagesRealignWhenTheUserIsKnown() throws {
        let harness = Harness()
        let shown = messages(0..<6)
        harness.coordinator.update(
            MessageTable(
                rows: TimelineRow.rows(shown), meID: "", kind: .space, actions: MessageRowActions(), nearTop: {}))
        harness.settle()
        harness.show(shown)  // the signed-in user arrives: meID "me"
        let mine = try #require(harness.coordinator.rows.firstIndex { $0.message.sender.id == "me" })
        let view = try #require(harness.table.rowView(atRow: mine, makeIfNecessary: false) as? MessageRowView)
        #expect(view.rowLayout?.bubble.maxX ?? 0 > harness.table.bounds.width / 2, "own bubble should be right-aligned")
    }

    /// Older history is asked for three screens before the top, and again as each page lands while the reader is
    /// still there, so a fast scroll keeps paging; a page that adds nothing asks no more.
    @Test func olderPagesKeepLoadingWhileTheReaderIsNearTheTop() {
        let harness = Harness()
        harness.show(messages(100..<300))
        #expect(harness.nearTop == 0, "at the newest message, far from the top")
        harness.scroll(to: MessageTable.Coordinator.topZone(visibleHeight: harness.clip.height) + 400)
        #expect(harness.nearTop == 0)
        harness.scroll(to: 0)
        #expect(harness.nearTop == 1, "entering the zone")
        harness.scroll(to: 50)
        #expect(harness.nearTop == 1, "scrolling within the zone asks nothing more")
        harness.show(messages(95..<300))  // a page lands; the reader is still near the top
        #expect(harness.visibleTop < MessageTable.Coordinator.topZone(visibleHeight: harness.clip.height))
        #expect(harness.nearTop == 2, "the next page is asked for at once")
        harness.show(messages(95..<300))  // nothing new
        harness.scroll(to: 0)
        #expect(harness.nearTop == 2, "a page that adds no rows does not loop")
        harness.scroll(to: harness.table.bounds.height)
        harness.scroll(to: 0)
        #expect(harness.nearTop == 3, "re-entering the zone asks again")
    }
    /// Scrolling reuses row views, as a table should: the views ever made stay near a screenful, however long the history.
    @Test func scrollingALongHistoryReusesRowViews() {
        let harness = Harness()
        harness.show(messages(0..<600))
        var made = Set<ObjectIdentifier>()
        func note() {
            for rowIndex in 0..<harness.table.numberOfRows {
                if let view = harness.table.rowView(atRow: rowIndex, makeIfNecessary: false) {
                    made.insert(ObjectIdentifier(view))
                }
            }
        }
        var y: CGFloat = harness.table.bounds.height
        while y > 0 {
            y -= 300
            harness.scroll(to: max(0, y))
            note()
        }
        let screenful = Int(harness.clip.height / 40) + 10
        #expect(made.count < screenful * 3, "\(made.count) row views for \(harness.table.numberOfRows) rows")
    }
    /// The keyboard reaches a message, as in Mail: ↑ and ↓ move between them, Return replies in its thread, E edits one of
    /// mine, Delete asks to delete one of mine, and Esc leaves the list.
    @Test func theKeyboardSelectsAndActsOnMessages() throws {
        var calls: [String] = []
        let harness = Harness()
        harness.actions.openThread = { calls.append("thread \($0.id)") }
        harness.actions.quote = { calls.append("quote \($0.id)") }
        harness.actions.edit = { calls.append("edit \($0.id)") }
        harness.actions.delete = { calls.append("delete \($0.id)") }
        harness.show(messages(0..<6))  // every third is mine: m0000, m0003
        let table = try #require(harness.table as? TimelineTableView)
        func press(_ keyCode: UInt16, _ characters: String) throws {
            table.keyDown(
                with: try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: harness.window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                        keyCode: keyCode)))
        }
        harness.window.makeFirstResponder(table)
        table.selectLast()
        #expect(table.selectedRow == 5)
        try press(126, "\u{F700}")  // ↑
        #expect(table.selectedRow == 4)
        try press(36, "\r")  // Return: replies in m0004's thread
        try press(14, "e")  // not mine: nothing
        try press(126, "\u{F700}")
        try press(51, "\u{7F}")  // m0003 is mine: Delete asks first (the action does)
        try press(14, "e")  // edits it, in the composer
        #expect(calls == ["thread m0004", "delete m0003", "edit m0003"])
        #expect(table.selectedRow == -1)  // the edit took the keyboard back to the composer
        table.selectLast()
        try press(53, "\u{1B}")  // Esc leaves the list
        #expect(table.selectedRow == -1)
    }
    /// A page's pictures are fetched and decoded into the cache as it lands, before their rows scroll into view.
    @Test func aLandedPageWarmsItsThumbnails() async throws {
        // The pictures' URLs are new, so the shared cache has none of them. Clearing it would also wipe other tests' entries.
        let harness = Harness()
        let fake = FakeBackend()
        var fetched = 0
        harness.actions.loadAttachment = { attachment, thumbnail in
            fetched += 1
            return try await fake.attachmentData(attachment, thumbnail: thumbnail)
        }
        let pictures = (0..<6).map {
            Attachment(
                name: "p\($0).png", contentType: "image/png", kind: .image,
                url: URL(string: "https://example.com/warm-\(UUID())"), width: 1200, height: 900)
        }
        var older = messages(0..<6)
        for rowIndex in older.indices { older[rowIndex].attachments = [pictures[rowIndex]] }
        harness.show(messages(6..<40))
        harness.show(older + messages(6..<40))
        // The shared cache is the app's: tests running alongside fill it, and with its memory budget it may let one of
        // these go again. What this test owns is the fetch (each picture once) and the decode (at display size).
        await eventually(timeout: .seconds(5)) {
            fetched == pictures.count && pictures.allSatisfy { ImageCache.cached($0) != nil }
        }
        #expect(fetched == pictures.count, "rows on screen and the prefetch share one fetch per picture")
        let kept = pictures.filter { ImageCache.cached($0) != nil }
        for picture in pictures {
            guard let image = ImageCache.cached(picture) else { continue }
            #expect(
                max(image.size.width, image.size.height) <= CGFloat(picture.displayPixels), "decoded at display size")
        }
        #expect(!kept.isEmpty, "the warmed pictures went into the cache")
    }
}
