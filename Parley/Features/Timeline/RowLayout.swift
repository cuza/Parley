import AppKit
import ParleyDomain

/// How messages look (Settings ▸ Message style): Telegram's bubbles, or its plain list where everyone is on the left.
enum TimelineStyle: String, CaseIterable, Sendable { case bubbles, plain }

/// Where everything in one timeline row goes at one width: a pure function of the row, computed before any view
/// exists, so `heightOfRow` only reads it and the row view only applies it.
/// Frames are in row coordinates, top-left origin. Content frames lie inside `bubble`; the tail and avatar outside it.
struct RowLayout: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat = 0
    var dateHeader: CGRect?
    var avatar: CGRect?
    /// The bubble's body. A tail, on the run's last bubble, grows `tailWidth` out of its bottom corner on the sender's side.
    var bubble: CGRect = .zero
    var tail = false
    var name: CGRect?
    var via: CGRect?  // after the name: a grey capsule naming the app that posted for the sender
    var quote: CGRect?  // the tinted block; its bar runs down the block's leading `quoteBar` points
    var quoteSender: CGRect?
    var quoteText: CGRect?
    var text: CGRect?
    var attachments: [CGRect] = []
    /// Which of a flush picture's corners the bubble rounds (nil: not flush).
    var attachmentCorners: [Corners?] = []
    struct Corners: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let topLeft = Corners(rawValue: 1), topRight = Corners(rawValue: 2), bottomLeft = Corners(rawValue: 4),
            bottomRight = Corners(rawValue: 8)
    }
    var reactions: [CGRect] = []  // one pill per `message.reactions` entry
    var replies: CGRect?
    var sources: CGRect?  // a Gemini answer's "N Sources" line, which pops its sources up
    var translation: CGRect?  // a translated message's "View original (…)" / "Show translation" toggle
    var thinking: CGRect?  // a Gemini answer's "Show thinking" line, above its text
    var time: CGRect = .zero  // also carries "edited" / "Sending…"
    var retry: CGRect?  // under the bubble when the send failed
    var service: CGRect?  // a system event's centered line ("Ana added Ben"); then there is no bubble
    var seen: CGRect?  // "Seen" / "Seen by …" under my message, when readers' receipts end here
    var bare = false  // no bubble: large emoji (the time on a pill) or a message of cards only, or of pictures only
    var mediaOnly = false  // pictures alone: drawn with rounded corners and no bubble, the time on a pill over the last one
    var reactionsOutside = false  // under a bubble that ends with a picture (or under pictures alone), not in it
    var timeOnly = false  // the picture is too narrow for the pill's "edited" / star extras: it shows the time alone

    static let margin: CGFloat = 14, avatarSize: CGFloat = 28, avatarGap: CGFloat = 6, tailWidth: CGFloat = 6
    static let padX: CGFloat = 11, padY: CGFloat = 6, spacing: CGFloat = 4, timeGap: CGFloat = 8,
        maxBubble: CGFloat = 500
    static let quoteBar: CGFloat = 3, cornerRadius: CGFloat = 17.5  // Telegram's bubble: a 35 pt circle's corners
    /// A message of nothing but pictures, videos and GIFs has no bubble (Telegram): they stand alone, rounded.
    static func mediaOnly(_ message: Message, style: TimelineStyle = .bubbles) -> Bool {
        style == .bubbles && !message.attachments.isEmpty && message.text.isEmpty && message.quote == nil
            && message.thinking.isEmpty
            && message.sources.isEmpty && message.jumboEmoji == nil
            && message.attachments.allSatisfy(isMedia)
    }
    /// A bubble with something else in it and a picture: the picture fills the bubble but for a 1 pt edge of bubble colour
    /// (Telegram's `mediaBubbleCornerInset`), the caption under it.
    static func fillsBubble(_ message: Message, style: TimelineStyle = .bubbles) -> Bool {
        style == .bubbles && !mediaOnly(message, style: style) && message.attachments.contains(where: isMedia)
    }
    /// A picture, video or GIF (not an app card's): in a bubble it fills the bubble's width, flush to its edges.
    static func isMedia(_ attachment: Attachment) -> Bool {
        (attachment.kind == .image || attachment.kind == .video) && attachment.card == nil
    }
    /// Telegram's numbers: the 1 pt edge of bubble round a picture in a bubble, and the gap between stacked pictures.
    static let mediaInset: CGFloat = 1, mediaGap: CGFloat = 4
    /// The time rides on a pill over the last picture's corner when a picture is the message's last block (a quote or
    /// sender line or a caption may sit above it, nothing under it, so no caption), so the bubble ends right below it.
    static func timeOnPicture(_ message: Message, style: TimelineStyle = .bubbles) -> Bool {
        if mediaOnly(message, style: style) { return true }
        guard style == .bubbles, message.thinking.isEmpty, message.sources.isEmpty,
            message.replyCount == 0, message.jumboEmoji == nil, message.text.isEmpty,
            let last = message.attachments.last
        else { return false }
        return isMedia(last)
    }
    /// One set of numbers for every picture, in a bubble or alone (Telegram's): a capsule time pill 16 pt high, 5 pt from
    /// the picture's right edge and 7 from its bottom; a picture's corners at the bubble's corners (or all four, alone) are
    /// 17, the others 5.
    static let mediaPillInset = NSSize(width: 5, height: 1.5), mediaPillMargin = NSSize(width: 5, height: 7)
    static let mediaRadius: CGFloat = 17, mediaInnerRadius: CGFloat = 5
    /// Between a picture and a quote above it or a caption under it.
    static let mediaSpacing: CGFloat = 7
    /// A picture's size as Telegram lays it out (`ChatLayoutUtils.contentSize`): fitted into a `min(room, 320)` square;
    /// a small one (both sides under 100) enlarged to fit 200 x 200; a video grown to about 300 on its shorter side, a
    /// landscape one up to 420 wide; with a caption, at least the square's width (a blur fills the sides). At least 100
    /// wide and 46 high.
    static func mediaSize(_ attachment: Attachment, caption: Bool, room: CGFloat) -> CGSize {
        let box = min(room, 320)
        var natural = CGSize(width: CGFloat(attachment.width ?? 0), height: CGFloat(attachment.height ?? 0))
        var size: CGSize
        if attachment.kind == .video {
            if natural.width <= 0 || natural.height <= 0 { natural = CGSize(width: 300, height: 300) }
            let addition = max(300 - natural.width, 300 - natural.height)
            if addition > 0 {
                natural = CGSize(
                    width: natural.width + addition * natural.width / natural.height, height: natural.height + addition)
            }
            size =
                natural.width > natural.height
                ? aspectFitted(natural, CGSize(width: min(420, room), height: natural.height)) : fitted(natural, box)
        } else {
            size = natural.width > 0 && natural.height > 0 ? fitted(natural, box) : CGSize(width: box, height: box)
            if size.width < 100 && size.height < 100 { size = aspectFitted(size, CGSize(width: 200, height: 200)) }
        }
        if caption { size.width = max(box, size.width) }
        return CGSize(width: min(room, max(100, 46, size.width)), height: max(46, size.height))
    }
    private static func fitted(_ size: CGSize, _ side: CGFloat) -> CGSize {
        var size = size
        if size.width > side { size = CGSize(width: side, height: ceil(size.height * side / size.width)) }
        if size.height > side { size = CGSize(width: ceil(size.width * side / size.height), height: side) }
        return size
    }
    private static func aspectFitted(_ size: CGSize, _ box: CGSize) -> CGSize {
        let scale = min(box.width / max(1, size.width), box.height / max(1, size.height))
        return CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }
    static let serviceInset = NSSize(width: 10, height: 3)
    /// The time beside large emoji sits on a pill half as padded as a service line's.
    static let jumboTimeInset = NSSize(width: serviceInset.width / 2, height: serviceInset.height / 2)
    /// A reaction pill's padding round its emoji and count.
    static let pillInset = NSSize(width: 7, height: 3)
    static let serviceLines = 6  // a longer service line (a space description) is cut; the row's tooltip has all of it
    static let viaInset = NSSize(width: 5, height: 1), viaGap: CGFloat = 6
    /// Counts measuring work on the task that binds it (tests): each layout made, as "id@width", and each text measure.
    @TaskLocal static var tally: MeasureTally?

    /// `AttachmentView`'s size for a known attachment: media from its dimensions, cards and chips from their text,
    /// all within `maxWidth` (the bubble's inner width, narrow in the thread pane); media keeps its aspect ratio.
    static func attachmentSize(
        _ attachment: Attachment, maxWidth: CGFloat = .greatestFiniteMagnitude, transcriptOpen: Bool = false
    ) -> CGSize {
        if attachment.kind == .voice {
            return VoiceLayout.size(attachment.voice, maxWidth: maxWidth, open: transcriptOpen)
        }
        if let card = attachment.card { return CardLayout.size(card, maxWidth: maxWidth, expanded: transcriptOpen) }
        if attachment.kind == .image || attachment.kind == .video {
            let size = attachment.mediaSize
            guard size.width > maxWidth else { return size }
            return CGSize(width: maxWidth, height: floor(size.height * maxWidth / size.width))
        }
        if attachment.domain != nil {
            let cardWidth = min(320, maxWidth)
            // ponytail: card text measured with AppKit's text-style fonts; SwiftUI's Text may differ by a point or two.
            let width = cardWidth - 20
            var height = attachment.cardImageHeight + 16
            height +=
                measure(styled(attachment.name, .preferredFont(forTextStyle: .callout).bold), width: width, lines: 2)
                .height
            if let snippet = attachment.snippet, snippet != attachment.name {
                height +=
                    2 + measure(styled(snippet, .preferredFont(forTextStyle: .caption1)), width: width, lines: 2).height
            }
            height +=
                2
                + measure(
                    styled(attachment.domain ?? "", .preferredFont(forTextStyle: .caption2)), width: width, lines: 1
                ).height
            return CGSize(width: cardWidth, height: ceil(height))
        }
        // 10 + 28 icon + 8 + text + 10, at most 280 wide.
        let name = measure(
            styled(attachment.name, .systemFont(ofSize: NSFont.systemFontSize), oneLine: true),
            width: .greatestFiniteMagnitude)
        let detail = measure(
            styled(attachment.detail, .preferredFont(forTextStyle: .caption1), oneLine: true),
            width: .greatestFiniteMagnitude)
        return CGSize(
            width: min(280, maxWidth, 46 + max(name.width, detail.width) + 10),
            height: max(28, name.height + 1 + detail.height) + 14)
    }
}

final class MeasureTally: @unchecked Sendable {  // written only by the task that binds it
    var rows: [String] = [], texts = 0
}

extension NSFont {
    fileprivate var bold: NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(.bold), size: pointSize) ?? self
    }
}
