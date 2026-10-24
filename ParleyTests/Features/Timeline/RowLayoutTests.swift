import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

struct RowLayoutTests {
    /// Message text is measured once; only a line broken inside a word (a long URL) is measured again at the narrower
    /// width the text view takes, where it may break once more.
    @Test func messageTextIsMeasuredOnceUnlessAWordBreaks() {
        let url = "https://example.com/" + String(repeating: "averyveryverylongpathsegment", count: 6)
        for (text, measures) in [("ok", 1), (RowFixtures.long, 1), ("see " + url + " now", 2)] {
            let tally = MeasureTally()
            let layout = RowLayout.$tally.withValue(tally) {
                RowLayout.make(RowFixtures.row(text), width: 640, own: false, kind: .group)
            }
            #expect(tally.texts == measures, "\(text.prefix(12)): \(tally.texts) measures")
            // As tall as measuring at the fitted width again says.
            let styled = MessageTextStyle.styled(text, own: false)
            let inner = layout.text!.width
            #expect(
                layout.text!.height >= MessageTextStyle.measure(styled, width: inner).size.height, "\(text.prefix(12))")
        }
    }
    @Test func sameInputSameLayout() {
        let row = RowFixtures.row(RowFixtures.long)
        #expect(
            RowLayout.make(row, width: 640, own: false, kind: .group)
                == RowLayout.make(row, width: 640, own: false, kind: .group))
    }
    @Test func wrappingFollowsWidth() {
        let row = RowFixtures.row(RowFixtures.long)
        let wide = RowLayout.make(row, width: 900, own: false, kind: .group)
        let narrow = RowLayout.make(row, width: 400, own: false, kind: .group)
        #expect(narrow.height > wide.height)
        #expect(narrow.text!.height > wide.text!.height && narrow.bubble.width < wide.bubble.width)
        #expect(wide.bubble.width <= RowLayout.maxBubble)
    }
    @Test func aCardSitsBelowTheBubbleNotInsideIt() {
        let card = Attachment(
            name: "Plan", kind: .card,
            card: Card(sections: [
                [.text("Alex resolved a comment", [])],
                [.links([.init(title: "Open", url: URL(string: "https://example.com")!)])],
            ]))
        let row = RowFixtures.row("Alex resolved a comment in Plan") { $0.attachments = [card] }
        for own in [false, true] {
            let layout = RowLayout.make(row, width: 700, own: own, kind: .space)
            let frame = layout.attachments[0]
            #expect(frame.minY >= layout.bubble.maxY + RowLayout.spacing)
            #expect(own ? frame.maxX == layout.bubble.maxX : frame.minX == layout.bubble.minX)
            #expect(layout.time.maxY <= layout.bubble.maxY && frame.maxY < layout.height)
            #expect(layout.avatar.map { $0.maxY == frame.maxY } ?? own)  // beside the card, the run's bottom
        }
    }
    @Test func everyElementLiesInsideTheBubbleAndTheRow() {
        let row = RowFixtures.row("Look at this", newDay: true) {
            $0.quote = QuotedMessage(sender: "Sam", text: RowFixtures.long)
            $0.attachments = [
                Attachment.fixture(.image, width: 1200, height: 800),
                Attachment(name: "report.pdf", contentType: "application/pdf", kind: .file),
                Attachment(
                    name: "Example", kind: .link, url: URL(string: "https://example.com"), snippet: "A page",
                    domain: "example.com"),
            ]
            $0.reactions = [Reaction(emoji: "👍", people: ["a", "b"]), Reaction(emoji: "❤️", people: ["me"])]
            $0.replyCount = 3
            $0.edited = true
            $0.delivery = .failed
        }
        for own in [false, true] {
            for width in [420.0, 700, 1100] {
                let layout = RowLayout.make(row, width: width, own: own, kind: .space)
                let inner =
                    [
                        layout.name, layout.quote, layout.quoteSender, layout.quoteText, layout.text, layout.replies,
                        layout.time,
                    ]
                    .compactMap { $0 } + layout.attachments + layout.reactions
                #expect(layout.attachments.count == 3 && layout.reactions.count == 2)
                for rect in inner {
                    #expect(
                        layout.bubble.contains(rect), "\(rect) outside bubble \(layout.bubble) at \(width), own \(own)")
                }
                for rect in [layout.quoteSender!, layout.quoteText!] { #expect(layout.quote!.contains(rect)) }
                let bounds = CGRect(x: 0, y: 0, width: width, height: layout.height)
                let tailed = layout.bubble.insetBy(dx: -RowLayout.tailWidth, dy: 0)
                for rect in [tailed, layout.dateHeader!, layout.retry!] + [layout.avatar].compactMap({ $0 }) {
                    #expect(bounds.contains(rect), "\(rect) outside row \(bounds)")
                }
                #expect(layout.dateHeader!.maxY <= layout.bubble.minY && layout.bubble.maxY <= layout.retry!.minY)
            }
        }
    }
    @Test func ownBubblesHugTheRightIncomingOnesTheLeftWithAnAvatar() {
        let row = RowFixtures.row("hello")
        let own = RowLayout.make(row, width: 700, own: true, kind: .group)
        #expect(own.bubble.maxX == 700 - RowLayout.margin - RowLayout.tailWidth && own.avatar == nil)
        let incoming = RowLayout.make(row, width: 700, own: false, kind: .group)
        #expect(incoming.avatar!.minX == RowLayout.margin && incoming.bubble.minX > incoming.avatar!.maxX)
        #expect(incoming.avatar!.maxY == incoming.bubble.maxY)
        #expect(RowLayout.make(row, width: 700, own: false, kind: .direct).avatar == nil)
        #expect(
            RowLayout.make(RowFixtures.row("hello", ends: false), width: 700, own: false, kind: .group).avatar == nil)
    }
    @Test func aDateHeaderAddsItsHeight() {
        let plain = RowLayout.make(RowFixtures.row("hi"), width: 600, own: false, kind: .group)
        let dated = RowLayout.make(RowFixtures.row("hi", newDay: true), width: 600, own: false, kind: .group)
        #expect(plain.dateHeader == nil)
        #expect(dated.height == plain.height + (dated.bubble.minY - plain.bubble.minY) && dated.height > plain.height)
    }
    @Test func theNameShowsOnARunsFirstIncomingBubbleInGroups() {
        #expect(RowLayout.make(RowFixtures.row("hi"), width: 600, own: false, kind: .group).name != nil)
        #expect(RowLayout.make(RowFixtures.row("hi"), width: 600, own: false, kind: .direct).name == nil)
        #expect(RowLayout.make(RowFixtures.row("hi"), width: 600, own: true, kind: .group).name == nil)
        #expect(RowLayout.make(RowFixtures.row("hi", begins: false), width: 600, own: false, kind: .group).name == nil)
    }
    @Test func theTimeSitsAfterTheLastLineWhenItFitsElseBelow() {
        var inline = 0
        var below = 0
        for count in 1...80 {
            let layout = RowLayout.make(
                RowFixtures.row(String(repeating: "word ", count: count).trimmingCharacters(in: .whitespaces)),
                width: 500, own: false, kind: .direct)
            let text = layout.text!
            if layout.time.minY < text.maxY {
                inline += 1
                #expect(layout.time.maxY == text.maxY)
            } else {
                below += 1
                #expect(layout.time.minY >= text.maxY)
            }
            #expect(layout.bubble.contains(layout.time))
        }
        #expect(inline > 0 && below > 0)
        let short = RowLayout.make(RowFixtures.row("ok"), width: 500, own: false, kind: .direct)
        #expect(short.time.minY < short.text!.maxY && short.time.minX >= short.text!.minX)
    }
    @Test func attachmentsTakeAttachmentViewsSizes() {
        let image = Attachment.fixture(.image, width: 1200, height: 800)
        #expect(RowLayout.attachmentSize(image) == image.mediaSize)
        #expect(image.mediaSize == CGSize(width: 320, height: (CGFloat(800) * 320 / 1200).rounded()))  // whole points
        #expect(RowLayout.attachmentSize(Attachment(name: "x", kind: .link, domain: "e.com")).width == 320)
        #expect(
            RowLayout.attachmentSize(Attachment(name: String(repeating: "long name ", count: 20), kind: .file)).width
                == 280)
        // Seen live: in the narrow thread pane an image ran past the bubble's leading edge. Everything fits the bubble.
        let narrow = RowLayout.attachmentSize(image, maxWidth: 200)
        #expect(narrow.width == 200 && abs(narrow.height / narrow.width - 800.0 / 1200) < 0.01)
        #expect(
            RowLayout.attachmentSize(Attachment(name: "x", kind: .link, domain: "e.com"), maxWidth: 200).width == 200)
        #expect(
            RowLayout.attachmentSize(
                Attachment(name: String(repeating: "long name ", count: 20), kind: .file), maxWidth: 200
            ).width == 200)
    }
    /// Telegram's media sizes (`ChatLayoutUtils.contentSize`).
    @Test func mediaIsSizedAsTelegramSizesIt() {
        func size(
            _ width: Int?, _ height: Int?, _ kind: ParleyDomain.Attachment.Kind = .image, caption: Bool = false,
            room: CGFloat = 498
        ) -> CGSize {
            RowLayout.mediaSize(
                Attachment(name: "x", kind: kind, width: width, height: height), caption: caption, room: room)
        }
        #expect(size(1200, 800) == CGSize(width: 320, height: 214))  // fitted into a 320 square
        #expect(size(60, 60) == CGSize(width: 200, height: 200))  // small: enlarged into 200 x 200
        #expect(size(400, 1200) == CGSize(width: 107, height: 320))  // tall: 320 high, not more
        #expect(size(400, 1200, caption: true) == CGSize(width: 320, height: 320))  // a caption: the square's width, a blur at the sides
        #expect(size(50, 400) == CGSize(width: 100, height: 320))  // at least 100 wide
        #expect(size(640, 480, .video) == CGSize(width: 420, height: 315))  // landscape video: up to 420 wide
        #expect(size(160, 90, .video) == CGSize(width: 420, height: 236))  // a small video grows to about 300 on its short side
        #expect(size(1200, 800, room: 150) == CGSize(width: 150, height: 100))  // a narrow pane
        #expect(size(nil, nil) == CGSize(width: 320, height: 320))
    }
    @Test func aMessageOfPicturesAloneHasNoBubbleNameOrTail() {
        let image = Attachment.fixture(.image, width: 1200, height: 800)
        let video = Attachment(name: "b.mp4", kind: .video, width: 640, height: 480)
        for own in [false, true] {
            let one = RowLayout.make(
                RowFixtures.row("") { $0.attachments = [image] }, width: 700, own: own, kind: .space)
            #expect(one.bare && one.mediaOnly && !one.tail && one.name == nil)
            #expect(one.attachments == [one.bubble] && one.bubble.size == CGSize(width: 320, height: 214))
            // The time is a pill 5 pt from the picture's right edge and 7 from its bottom.
            #expect(one.time.maxX == one.bubble.maxX - 5 && one.time.maxY == one.bubble.maxY - 7)
            let two = RowLayout.make(
                RowFixtures.row("") { $0.attachments = [image, video] }, width: 700, own: own, kind: .direct)
            #expect(
                two.attachments[1].minY == two.attachments[0].maxY + RowLayout.mediaGap
                    && two.attachments[1].contains(two.time))
            // Reactions go 4 pt under the picture, on the sender's side; the time stays on it.
            let reacted = RowLayout.make(
                RowFixtures.row("") {
                    $0.attachments = [image]
                    $0.reactions = [Reaction(emoji: "👍", people: ["a"])]
                },
                width: 700, own: own, kind: .direct)
            #expect(
                reacted.reactionsOutside && reacted.reactions[0].minY == reacted.bubble.maxY + 4
                    && reacted.attachments[0].contains(reacted.time))
            #expect(
                own
                    ? reacted.reactions[0].maxX == reacted.bubble.maxX
                    : reacted.reactions[0].minX == reacted.bubble.minX)
        }
        // A caption, a quote or another kind of attachment keep the bubble.
        let file = Attachment(name: "r.pdf", contentType: "application/pdf", kind: .file)
        for row in [
            RowFixtures.row("caption") { $0.attachments = [image] },
            RowFixtures.row("") { $0.attachments = [image, file] },
            RowFixtures.row("") {
                $0.attachments = [image]
                $0.quote = QuotedMessage(sender: "Sam", text: "hi")
            },
        ] {
            let layout = RowLayout.make(row, width: 700, own: false, kind: .direct)
            #expect(!layout.bare && !layout.mediaOnly && layout.tail)
        }
        let plain = RowLayout.make(
            RowFixtures.row("") { $0.attachments = [image] }, width: 700, own: false, kind: .direct, style: .plain)
        #expect(!plain.mediaOnly && plain.attachments[0].minX == plain.bubble.minX + RowLayout.padX)
    }
    /// A picture in a bubble sits 1 pt inside it on every side it meets (a thin edge of bubble colour), and sets its width.
    @Test func aPictureFillsItsBubbleButForAOnePointEdge() throws {
        let sam = QuotedMessage(sender: "Sam", text: "hi")
        let image = Attachment.fixture(.image, width: 1200, height: 800)
        let video = Attachment(name: "b.mp4", kind: .video, width: 640, height: 480)
        for own in [false, true] {
            // A quote above, no caption: the picture ends the bubble, the time on it; the tail still shows on a run's last.
            let quoted = RowLayout.make(
                RowFixtures.row("") {
                    $0.attachments = [image]
                    $0.quote = sam
                }, width: 700, own: own, kind: .direct)
            let picture = quoted.attachments[0]
            let quote = try #require(quoted.quote)
            #expect(quoted.bubble.width == 322 && picture.width == 320 && picture.height == 214)
            #expect(
                picture.minX == quoted.bubble.minX + 1 && picture.maxX == quoted.bubble.maxX - 1
                    && picture.maxY == quoted.bubble.maxY - 1)
            #expect(picture.minY == quote.maxY + RowLayout.mediaSpacing && quoted.tail)
            #expect(quoted.time.maxX == picture.maxX - 5 && quoted.time.maxY == picture.maxY - 7)
            #expect(quoted.attachmentCorners[0] == [.bottomLeft, .bottomRight])
            // A caption under it: the picture 1 pt from the top and sides, the text 7 pt under it, the time inline with the text.
            let captioned = RowLayout.make(
                RowFixtures.row(RowFixtures.long) { $0.attachments = [image] }, width: 700, own: own, kind: .direct)
            let top = captioned.attachments[0]
            let text = try #require(captioned.text)
            #expect(
                top.minY == captioned.bubble.minY + 1 && top.minX == captioned.bubble.minX + 1
                    && captioned.bubble.width == 322)
            #expect(
                text.minY == top.maxY + RowLayout.mediaSpacing && text.minX == captioned.bubble.minX + RowLayout.padX)
            #expect(
                text.maxX <= captioned.bubble.maxX - RowLayout.padX && !top.contains(captioned.time) && captioned.tail)
            #expect(captioned.attachmentCorners[0] == [.topLeft, .topRight])
            // Two pictures stack 4 pt apart, both the widest one's width.
            let two = RowLayout.make(
                RowFixtures.row("two") { $0.attachments = [image, video] }, width: 700, own: own, kind: .direct)
            #expect(
                two.attachments[1].minY == two.attachments[0].maxY + RowLayout.mediaGap
                    && two.attachments[0].width == two.attachments[1].width)
            #expect(two.attachmentCorners == [[.topLeft, .topRight], []])
            // Reactions on a caption-less one go outside, the bubble still ending at the picture.
            let reacted = RowLayout.make(
                RowFixtures.row("") {
                    $0.attachments = [image]
                    $0.quote = sam
                    $0.reactions = [Reaction(emoji: "👍", people: ["a"])]
                },
                width: 700, own: own, kind: .direct)
            #expect(
                reacted.reactionsOutside && reacted.attachments[0].maxY == reacted.bubble.maxY - 1
                    && reacted.reactions[0].minY == reacted.bubble.maxY + 4)
            // With a caption they stay inside, under it.
            let inside = RowLayout.make(
                RowFixtures.row("hi") {
                    $0.attachments = [image]
                    $0.reactions = [Reaction(emoji: "👍", people: ["a"])]
                },
                width: 700, own: own, kind: .direct)
            #expect(!inside.reactionsOutside && inside.bubble.contains(inside.reactions[0]))
        }
        // No name on a picture in a group, caption or not (Telegram's); other messages keep it.
        #expect(
            RowLayout.make(
                RowFixtures.row("caption") { $0.attachments = [image] }, width: 700, own: false, kind: .space
            ).name == nil)
        #expect(RowLayout.make(RowFixtures.row("text"), width: 700, own: false, kind: .space).name != nil)
        // A run's middle bubble has no tail.
        #expect(
            !RowLayout.make(
                RowFixtures.row("caption", ends: false) { $0.attachments = [image] }, width: 700, own: false,
                kind: .direct
            ).tail)
        // The widest the bubble gets is what the row has room for.
        let narrow = RowLayout.make(
            RowFixtures.row("") {
                $0.attachments = [image]
                $0.quote = sam
            }, width: 300, own: false, kind: .direct)
        #expect(narrow.attachments[0].maxX == narrow.bubble.maxX - 1 && narrow.bubble.maxX <= 300 - RowLayout.margin)
        // A file after the picture: the picture is not the last block, the time keeps its own line.
        let file = Attachment(name: "r.pdf", contentType: "application/pdf", kind: .file)
        let after = RowLayout.make(
            RowFixtures.row("") { $0.attachments = [image, file] }, width: 700, own: false, kind: .direct)
        #expect(after.attachments[0].maxY < after.bubble.maxY - 1 && !after.attachments[0].contains(after.time))
    }
}
