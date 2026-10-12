import AppKit

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
    var via: CGRect?          // after the name: a grey capsule naming the app that posted for the sender
    var quote: CGRect?        // the tinted block; its bar runs down the block's leading `quoteBar` points
    var quoteSender: CGRect?
    var quoteText: CGRect?
    var text: CGRect?
    var attachments: [CGRect] = []
    /// Which of a flush picture's corners the bubble rounds (nil: not flush). 
    var attachmentCorners: [Corners?] = []
    struct Corners: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let topLeft = Corners(rawValue: 1), topRight = Corners(rawValue: 2), bottomLeft = Corners(rawValue: 4), bottomRight = Corners(rawValue: 8)
    }
    var reactions: [CGRect] = []   // one pill per `message.reactions` entry
    var replies: CGRect?
    var sources: CGRect?           // a Gemini answer's "N Sources" line, which pops its sources up
    var translation: CGRect?       // a translated message's "View original (…)" / "Show translation" toggle
    var thinking: CGRect?          // a Gemini answer's "Show thinking" line, above its text
    var time: CGRect = .zero       // also carries "edited" / "Sending…"
    var retry: CGRect?             // under the bubble when the send failed
    var service: CGRect?           // a system event's centered line ("Ana added Ben"); then there is no bubble
    var seen: CGRect?              // "Seen" / "Seen by …" under my message, when readers' receipts end here
    var bare = false               // no bubble: large emoji (the time on a pill) or a message of cards only, or of pictures only
    var mediaOnly = false          // pictures alone: drawn with rounded corners and no bubble, the time on a pill over the last one
    var reactionsOutside = false   // under a bubble that ends with a picture (or under pictures alone), not in it
    var timeOnly = false           // the picture is too narrow for the pill's "edited" / star extras: it shows the time alone

    static let margin: CGFloat = 14, avatarSize: CGFloat = 28, avatarGap: CGFloat = 6, tailWidth: CGFloat = 6
    static let padX: CGFloat = 11, padY: CGFloat = 6, spacing: CGFloat = 4, timeGap: CGFloat = 8, maxBubble: CGFloat = 500
    static let quoteBar: CGFloat = 3, cornerRadius: CGFloat = 17.5   // Telegram's bubble: a 35 pt circle's corners
    /// A message of nothing but pictures, videos and GIFs has no bubble (Telegram): they stand alone, rounded.
    static func mediaOnly(_ message: Message, style: TimelineStyle = .bubbles) -> Bool {
        style == .bubbles && !message.attachments.isEmpty && message.text.isEmpty && message.quote == nil && message.thinking.isEmpty
            && message.sources.isEmpty && message.jumboEmoji == nil
            && message.attachments.allSatisfy(isMedia)
    }
    /// A bubble with something else in it and a picture: the picture fills the bubble but for a 1 pt edge of bubble colour
    /// (Telegram's `mediaBubbleCornerInset`), the caption under it.
    static func fillsBubble(_ message: Message, style: TimelineStyle = .bubbles) -> Bool {
        style == .bubbles && !mediaOnly(message, style: style) && message.attachments.contains(where: isMedia)
    }
    /// A picture, video or GIF (not an app card's): in a bubble it fills the bubble's width, flush to its edges.
    static func isMedia(_ attachment: Attachment) -> Bool { (attachment.kind == .image || attachment.kind == .video) && attachment.card == nil }
    /// Telegram's numbers: the 1 pt edge of bubble round a picture in a bubble, and the gap between stacked pictures.
    static let mediaInset: CGFloat = 1, mediaGap: CGFloat = 4
    /// The time rides on a pill over the last picture's corner when a picture is the message's last block (a quote or
    /// sender line or a caption may sit above it, nothing under it, so no caption), so the bubble ends right below it.
    static func timeOnPicture(_ message: Message, style: TimelineStyle = .bubbles) -> Bool {
        if mediaOnly(message, style: style) { return true }
        guard style == .bubbles, message.thinking.isEmpty, message.sources.isEmpty,
              message.replyCount == 0, message.jumboEmoji == nil, message.text.isEmpty, let last = message.attachments.last else { return false }
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
            if addition > 0 { natural = CGSize(width: natural.width + addition * natural.width / natural.height, height: natural.height + addition) }
            size = natural.width > natural.height ? aspectFitted(natural, CGSize(width: min(420, room), height: natural.height)) : fitted(natural, box)
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
    static let serviceLines = 6   // a longer service line (a space description) is cut; the row's tooltip has all of it
    static let viaInset = NSSize(width: 5, height: 1), viaGap: CGFloat = 6
    /// Counts measuring work on the task that binds it (tests): each layout made, as "id@width", and each text measure.
    @TaskLocal static var tally: MeasureTally?

    /// Sender names show on the first bubble of a run in groups and spaces; avatars sit beside the run's last
    /// incoming bubble there (Telegram shows neither in one-to-one chats).
    /// `.plain` lays every message out as incoming in a space, with the avatar beside the run's first message.
    static func make(_ row: TimelineRow, width: CGFloat, own: Bool, kind: ConversationKind, style: TimelineStyle = .bubbles) -> RowLayout {
        let plain = style == .plain, readersKind = kind
        let own = own && !plain, kind: ConversationKind = plain ? .space : kind
        let message = row.message
        tally?.rows.append("\(row.id)@\(width)")
        var layout = RowLayout(width: width)
        var y: CGFloat = 0
        if row.newDay {
            let text = measure(dateText(message), width: width)   // a pill over a wallpaper, so it keeps the service inset
            let size = CGSize(width: text.width + 2 * serviceInset.width, height: text.height + 2 * serviceInset.height)
            layout.dateHeader = CGRect(x: ((width - size.width) / 2).rounded(), y: 9, width: size.width, height: size.height)
            y += size.height + 18
        }
        if message.isSystem {   // Telegram's service message: a small centered pill between bubbles
            let size = measure(serviceText(message.text), width: max(40, width - 2 * margin - 2 * serviceInset.width), lines: serviceLines)
            let pill = CGSize(width: size.width + 2 * serviceInset.width, height: size.height + 2 * serviceInset.height)
            layout.service = CGRect(x: ((width - pill.width) / 2).rounded(), y: y + 8, width: pill.width, height: pill.height)
            layout.height = ceil(y + 8 + pill.height + 8)
            return layout
        }
        y += row.begins ? 8 : 1

        let avatars = !own && kind != .direct
        let leading = margin + (avatars ? avatarSize + avatarGap : 0) + tailWidth
        let mediaOnly = Self.mediaOnly(message, style: style)
        let padX = mediaOnly ? 0 : Self.padX, padY = mediaOnly ? 0 : Self.padY   // pictures alone are flush
        let maxBubble = max(80, min(Self.maxBubble, width - leading - margin - tailWidth - 40))   // 40: a gutter on the far side
        // Pictures fill the bubble but for its 1 pt edge and set its width (the widest of them); text wraps within it.
        let flushMedia = Self.fillsBubble(message, style: style) ? message.attachments.filter(Self.isMedia) : []
        let caption = !message.text.isEmpty
        let mediaWidth: CGFloat? = flushMedia.map { Self.mediaSize($0, caption: caption, room: maxBubble - 2 * mediaInset).width }.max()
        let mediaBubble = mediaWidth.map { $0 + 2 * mediaInset }   // the bubble's width
        let inner = (mediaBubble ?? maxBubble) - 2 * padX

        // Content, laid out from the bubble's top-left; `lastLine` is how far a text-like last line reaches, for the time.
        // `afterPicture`: the last block is a flush picture, so what follows keeps a full padding from it.
        var cy = padY, contentWidth: CGFloat = 0, placed = false, afterPicture = false
        var lastLine: (width: CGFloat, bottom: CGFloat)?
        func place(_ size: CGSize) -> CGRect {
            if placed { cy += afterPicture ? mediaSpacing : spacing }
            placed = true; afterPicture = false
            let rect = CGRect(x: padX, y: cy, width: size.width, height: size.height)
            cy += size.height; contentWidth = max(contentWidth, size.width)
            return rect
        }
        // A message that is only cards has no bubble: its sender, badge and time make one line over the card, as Google
        // Chat draws it, in a DM too.
        let cardOnly = message.text.isEmpty && message.quote == nil && message.thinking.isEmpty && !message.attachments.isEmpty
            && message.attachments.allSatisfy { $0.card != nil }
        if !own && (row.begins && kind != .direct && !(style == .bubbles && message.attachments.contains(where: Self.isMedia)) || cardOnly) {   // as Telegram: no name on a picture, video or GIF
            var name = measure(nameText(message.sender.name), width: inner)
            if let via = message.via {   // the name gives way to the badge, which keeps its size
                let text = measure(viaText(via), width: inner / 2)
                let badge = CGSize(width: text.width + 2 * viaInset.width, height: text.height + 2 * viaInset.height)
                name.width = min(name.width, max(0, inner - viaGap - badge.width))
                let line = place(CGSize(width: name.width + viaGap + badge.width, height: max(name.height, badge.height)))
                layout.name = CGRect(x: line.minX, y: line.minY + ((line.height - name.height) / 2).rounded(), width: name.width, height: name.height)
                layout.via = CGRect(x: line.minX + name.width + viaGap, y: line.minY + ((line.height - badge.height) / 2).rounded(),
                                    width: badge.width, height: badge.height)
            } else {
                layout.name = place(name)
            }
            let line = layout.name.map { CGRect(x: $0.minX, y: $0.minY, width: (layout.via?.maxX ?? $0.maxX) - $0.minX, height: max($0.height, layout.via?.height ?? 0)) }
            lastLine = cardOnly ? line.map { ($0.width, $0.maxY) } : nil   // the time follows the name
        }
        if !message.thinking.isEmpty {
            layout.thinking = place(measure(thinkingText(), width: inner)); lastLine = nil
        }
        if let quote = message.quote {
            let textWidth = inner - quoteBar - 15
            let sender = measure(quoteSenderText(quote), width: textWidth), body = measure(quoteBodyText(quote), width: textWidth, lines: 2)
            let block = place(CGSize(width: min(inner, max(sender.width, body.width) + quoteBar + 15), height: sender.height + body.height + 8))
            layout.quote = block
            layout.quoteSender = CGRect(x: block.minX + quoteBar + 7, y: block.minY + 4, width: sender.width, height: sender.height)
            layout.quoteText = CGRect(x: block.minX + quoteBar + 7, y: block.minY + 4 + sender.height, width: body.width, height: body.height)
            lastLine = nil
        }
        // A caption goes under the pictures that fill its bubble (so the tail has text beside it), else where it was written.
        func placeText() {
            guard !message.text.isEmpty else { return }
            let styled = MessageTextStyle.styled(message.text, message.formatting, own: own, jumbo: message.jumboEmoji)
            var measured = MessageTextStyle.measure(styled, width: inner)
            // The text view is only as wide as the widest measured line; a long word broken mid-way (a URL) can break again
            // at that width and take another line, so such text is measured again there. Lines broken between words
            // still fit at that width and break the same.
            // Keeps that width (the view's) and takes the height measured at it.
            if measured.brokeWord {
                let fitted = MessageTextStyle.measure(styled, width: measured.size.width)
                if fitted.size.height > measured.size.height {
                    measured = (CGSize(width: measured.size.width, height: fitted.size.height), fitted.lastLine, true)
                }
            }
            let rect = place(measured.size)
            layout.text = rect
            lastLine = (measured.lastLine, rect.maxY)
        }
        if flushMedia.isEmpty { placeText() }
        var cards: [(index: Int, size: CGSize)] = []
        for (index, attachment) in message.attachments.enumerated() {
            if attachment.card != nil {   // placed under the bubble, below
                cards.append((index, attachmentSize(attachment, maxWidth: maxBubble, transcriptOpen: row.transcriptOpen))); layout.attachments.append(.zero); continue
            }
            if let mediaWidth, Self.isMedia(attachment) {   // the bubble's width but for its edge; a narrower one has a blur at its sides
                let size = Self.mediaSize(attachment, caption: caption, room: maxBubble - 2 * mediaInset)
                cy = !placed ? mediaInset : cy + (afterPicture ? mediaGap : mediaSpacing)
                layout.attachments.append(CGRect(x: mediaInset, y: cy, width: mediaWidth, height: size.height))
                cy += size.height; placed = true; afterPicture = true; lastLine = nil
                continue
            }
            let size = mediaOnly && Self.isMedia(attachment) ? Self.mediaSize(attachment, caption: false, room: inner)
                : attachmentSize(attachment, maxWidth: inner, transcriptOpen: row.transcriptOpen)
            let rect = place(size)
            layout.attachments.append(rect)
            // A voice message's time sits level with its duration, as Telegram's does (room left for the speed toggle).
            lastLine = attachment.kind == .voice && attachment.voice?.transcript == nil ? (VoiceLayout.button + VoiceLayout.gap + 70, rect.maxY) : nil
        }
        if !flushMedia.isEmpty { placeText() }
        if !message.sources.isEmpty {
            let rect = place(measure(sourcesText(message.sources), width: inner))
            layout.sources = rect; lastLine = (rect.width, rect.maxY)
        }
        let pillOnPicture = Self.timeOnPicture(message, style: style) && !row.draft
        let lastMedia = pillOnPicture ? layout.attachments.last : nil
        // Reactions under a bubble that ends with a picture go outside it, the time staying on the picture (Telegram's).
        layout.reactionsOutside = pillOnPicture && !message.reactions.isEmpty
        if !message.reactions.isEmpty && !layout.reactionsOutside {
            if placed { cy += afterPicture ? mediaSpacing : spacing }
            placed = true; afterPicture = false
            let flow = reactionFlow(message.reactions, width: inner)
            layout.reactions = flow.pills.map { $0.offsetBy(dx: padX, dy: cy) }
            contentWidth = max(contentWidth, flow.size.width)
            cy += flow.size.height
            lastLine = (flow.lastLine, cy)
        }
        if message.replyCount > 0 || row.draft {
            let rect = place(measure(repliesText(message.replyCount, draft: row.draft), width: inner))
            layout.replies = rect; lastLine = (rect.width, rect.maxY)
        }
        // The time sits after the last line when it fits there (Telegram's inline date), else on a line of its own.
        var time = measure(timeText(message), width: inner)
        if let lastMedia, time.width + 2 * mediaPillInset.width + 2 * mediaPillMargin.width > lastMedia.width {
            layout.timeOnly = true; time = measure(timeText(message, timeOnly: true), width: inner)
        }
        var timeTop: CGFloat = 0
        if pillOnPicture {   // on a pill over the last picture's corner: takes no room
        } else if let lastLine, lastLine.width + timeGap + time.width <= inner {
            timeTop = lastLine.bottom - time.height
            contentWidth = max(contentWidth, lastLine.width + timeGap + time.width)
        } else {
            timeTop = placed ? cy + (afterPicture ? mediaSpacing : 2) : cy
            cy = timeTop + time.height
            contentWidth = max(contentWidth, time.width)
        }
        cy += lastMedia == nil ? padY : mediaWidth == nil ? 0 : mediaInset   // a picture with the time on it ends the bubble, but for its edge

        if mediaWidth != nil { contentWidth = inner }
        let bubbleWidth = mediaBubble ?? contentWidth + 2 * padX
        let bubble = CGRect(x: own ? width - margin - tailWidth - bubbleWidth : leading, y: y, width: bubbleWidth, height: cy)
        layout.bubble = bubble
        layout.tail = row.ends && !plain && !mediaOnly   // beside a picture too: it grows from the bubble's edge, outside the picture
        layout.time = CGRect(x: bubble.maxX - padX - time.width, y: bubble.minY + timeTop, width: time.width, height: time.height)
        layout.bare = message.jumboEmoji != nil || cardOnly || mediaOnly
        layout.mediaOnly = mediaOnly
        if let lastMedia {
            let pill = CGSize(width: time.width + 2 * mediaPillInset.width, height: time.height + 2 * mediaPillInset.height)
            layout.time = CGRect(x: bubble.minX + max(lastMedia.minX, lastMedia.maxX - mediaPillMargin.width - pill.width), y: bubble.minY + lastMedia.maxY - mediaPillMargin.height - pill.height,
                                 width: pill.width, height: pill.height)
        }
        if message.jumboEmoji != nil { layout.time = layout.time.insetBy(dx: -serviceInset.width / 2, dy: -serviceInset.height / 2) }   // room for the pill
        let offset = { (rect: CGRect) in rect.offsetBy(dx: bubble.minX, dy: bubble.minY) }
        layout.name = layout.name.map(offset); layout.via = layout.via.map(offset)
        layout.quote = layout.quote.map(offset); layout.quoteSender = layout.quoteSender.map(offset); layout.quoteText = layout.quoteText.map(offset)
        // As wide as the content (wraps the same: every measured line still fits), so code-block backgrounds fill the bubble.
        layout.text = layout.text.map { offset(CGRect(x: $0.minX, y: $0.minY, width: min(contentWidth, inner), height: $0.height)) }
        layout.attachmentCorners = zip(message.attachments, layout.attachments).map { attachment, rect in
            guard mediaWidth != nil, Self.isMedia(attachment) else { return nil }
            var corners: Corners = []
            if rect.minY == mediaInset { corners.formUnion([.topLeft, .topRight]) }
            if rect.maxY == bubble.height - mediaInset { corners.formUnion([.bottomLeft, .bottomRight]) }
            return corners
        }
        layout.attachments = layout.attachments.map(offset)
        layout.reactions = layout.reactions.map(offset)
        layout.replies = layout.replies.map(offset)
        layout.sources = layout.sources.map(offset)
        layout.thinking = layout.thinking.map(offset)
        y = bubble.maxY
        if layout.reactionsOutside {   // 4 pt under the bubble, on the sender's side
            let flow = reactionFlow(message.reactions, width: maxBubble)
            let x = own ? bubble.maxX - flow.size.width : bubble.minX
            layout.reactions = flow.pills.map { $0.offsetBy(dx: x, dy: y + 4) }
            y += 4 + flow.size.height
        }
        // A translated message's toggle sits under the bubble, on the sender's side, as Google Chat draws it.
        if let translation = message.translation {
            let size = measure(translationText(translation, showingOriginal: row.transcriptOpen), width: maxBubble)
            layout.translation = CGRect(x: own ? bubble.maxX - size.width : bubble.minX, y: y + 3, width: size.width, height: size.height)
            y += size.height + 3
        }
        // An app's card stands on its own under the bubble, as Google Chat draws it, on the sender's side.
        for card in cards {
            y += spacing
            layout.attachments[card.index] = CGRect(x: own ? bubble.maxX - card.size.width : bubble.minX, y: y, width: card.size.width, height: card.size.height)
            y += card.size.height
        }
        let bottom = y
        if message.delivery == .failed {
            let size = measure(retryText(), width: maxBubble)
            layout.retry = CGRect(x: own ? bubble.maxX - size.width : bubble.minX, y: y + 3, width: size.width, height: size.height)
            y += size.height + 3
        }
        if !row.seenBy.isEmpty {
            let size = measure(seenText(row.seenBy, kind: readersKind), width: maxBubble)
            layout.seen = CGRect(x: own ? bubble.maxX - size.width : bubble.minX, y: y + 2, width: size.width, height: size.height)
            y += size.height + 2
        }
        if plain && row.begins { layout.avatar = CGRect(x: margin, y: bubble.minY + 2, width: avatarSize, height: avatarSize) }
        else if !plain && avatars && row.ends { layout.avatar = CGRect(x: margin, y: bottom - avatarSize, width: avatarSize, height: avatarSize) }
        layout.height = ceil(y + 1)
        return layout
    }

    /// Reaction pills flowed onto lines `width` wide, from the origin: their frames, the block's size, the last line's width.
    private static func reactionFlow(_ reactions: [Reaction], width: CGFloat) -> (pills: [CGRect], size: CGSize, lastLine: CGFloat) {
        var pills: [CGRect] = [], x: CGFloat = 0, lineTop: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for reaction in reactions {
            let text = measure(pillText(reaction), width: width)
            let pill = CGSize(width: text.width + 14, height: text.height + 6)
            if x > 0 && x + pill.width > width { x = 0; lineTop += lineHeight + spacing; lineHeight = 0 }
            pills.append(CGRect(x: x, y: lineTop, width: pill.width, height: pill.height))
            x += pill.width + spacing; lineHeight = max(lineHeight, pill.height)
            widest = max(widest, x - spacing)
        }
        return (pills, CGSize(width: widest, height: lineTop + lineHeight), x - spacing)
    }

    /// `AttachmentView`'s size for a known attachment: media from its dimensions, cards and chips from their text,
    /// all within `maxWidth` (the bubble's inner width, narrow in the thread pane); media keeps its aspect ratio.
    static func attachmentSize(_ attachment: Attachment, maxWidth: CGFloat = .greatestFiniteMagnitude, transcriptOpen: Bool = false) -> CGSize {
        if attachment.kind == .voice { return VoiceLayout.size(attachment.voice, maxWidth: maxWidth, open: transcriptOpen) }
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
            height += measure(styled(attachment.name, .preferredFont(forTextStyle: .callout).bold), width: width, lines: 2).height
            if let snippet = attachment.snippet, snippet != attachment.name {
                height += 2 + measure(styled(snippet, .preferredFont(forTextStyle: .caption1)), width: width, lines: 2).height
            }
            height += 2 + measure(styled(attachment.domain ?? "", .preferredFont(forTextStyle: .caption2)), width: width, lines: 1).height
            return CGSize(width: cardWidth, height: ceil(height))
        }
        // 10 + 28 icon + 8 + text + 10, at most 280 wide.
        let name = measure(styled(attachment.name, .systemFont(ofSize: NSFont.systemFontSize), oneLine: true), width: .greatestFiniteMagnitude)
        let detail = measure(styled(attachment.detail, .preferredFont(forTextStyle: .caption1), oneLine: true), width: .greatestFiniteMagnitude)
        return CGSize(width: min(280, maxWidth, 46 + max(name.width, detail.width) + 10), height: max(28, name.height + 1 + detail.height) + 14)
    }

    // MARK: Label text, shared by the layout (measuring) and the row view (drawing with `TextLabel`)

    static func dateText(_ message: Message, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(message.createdAt.formatted(date: .abbreviated, time: .omitted), .systemFont(ofSize: 11, weight: .medium), color, oneLine: true)
    }
    static func nameText(_ name: String, color: NSColor = .labelColor) -> NSAttributedString {
        styled(name, .systemFont(ofSize: 13, weight: .semibold), color, oneLine: true)
    }
    static func viaText(_ app: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(app, .systemFont(ofSize: 10, weight: .medium), color, oneLine: true)
    }
    static func quoteSenderText(_ quote: QuotedMessage, color: NSColor = .labelColor) -> NSAttributedString {
        styled(quote.forwardedFrom.map { "↪ \(quote.sender) · from \($0)" } ?? quote.sender, .systemFont(ofSize: 12, weight: .semibold), color, oneLine: true)
    }
    /// The quoted text, its custom emoji drawn as pictures (as the pills draw theirs).
    static func quoteBodyText(_ quote: QuotedMessage, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let text = styled(quote.text, .systemFont(ofSize: 13), color)
        guard let emoji = quote.emoji, !emoji.isEmpty else { return text }
        let body = NSMutableAttributedString(attributedString: text)
        for range in emoji.sorted(by: { $0.start > $1.start }) where range.start + range.length <= body.length {
            guard case .customEmoji(let custom) = range.style else { continue }
            let at = NSRange(location: range.start, length: range.length)
            body.replaceCharacters(in: at, with: MessageTextStyle.customEmoji(custom, attributes: body.attributes(at: at.location, effectiveRange: nil)))
        }
        return body
    }
    static func timeText(_ message: Message, color: NSColor = .secondaryLabelColor, timeOnly: Bool = false) -> NSAttributedString {
        let time = message.delivery == .pending ? "Sending…" : shortTime(message.createdAt)
        return styled(timeOnly ? time : (message.starred ? "★ " : "") + (message.edited ? "edited " : "") + time, .systemFont(ofSize: 11), color, oneLine: true)
    }
    /// Formatted once per date: every layout and every row view needs its message's time.
    /// ponytail: a time zone or 12/24-hour change shows in newly formatted times only; key by both if it matters.
    private static func shortTime(_ date: Date) -> String {
        let key = NSNumber(value: date.timeIntervalSinceReferenceDate)
        if let cached = times.object(forKey: key) { return cached as String }
        let time = date.formatted(date: .omitted, time: .shortened)
        times.setObject(time as NSString, forKey: key)
        return time
    }
    nonisolated(unsafe) private static let times = NSCache<NSNumber, NSString>()   // NSCache is thread-safe
    static func pillText(_ reaction: Reaction, color: NSColor = .labelColor) -> NSAttributedString {
        let text = styled("\(reaction.custom == nil ? reaction.emoji : "\u{FFFD}") \(reaction.people.count)", .systemFont(ofSize: 12), color, oneLine: true)
        guard let custom = reaction.custom else { return text }
        let pill = NSMutableAttributedString(attributedString: text)
        pill.replaceCharacters(in: NSRange(location: 0, length: 1), with: MessageTextStyle.customEmoji(custom, attributes: text.attributes(at: 0, effectiveRange: nil)))
        return pill
    }
    /// "2 replies", with " · 1 draft" when the thread's reply box holds a draft, as Google Chat shows it.
    static func repliesText(_ count: Int, draft: Bool = false, color: NSColor = .controlAccentColor) -> NSAttributedString {
        let parts = [count == 0 ? nil : count == 1 ? "1 reply" : "\(count) replies", draft ? "1 draft" : nil].compactMap { $0 }
        return styled(parts.joined(separator: " · "), .systemFont(ofSize: 12, weight: .medium), color, oneLine: true)
    }
    /// Google Chat's words for the toggle: "View original (Spanish)" over a translation, "Show translation" over the original.
    static func translationLabel(_ translation: Translation, showingOriginal: Bool) -> String {
        if showingOriginal { return "Show translation" }
        guard let language = Locale.current.localizedString(forLanguageCode: translation.from), language != translation.from else { return "View original" }
        return "View original (\(language))"
    }
    /// The toggle in small type after a translate icon, as Google Chat draws it under the bubble.
    static func translationText(_ translation: Translation, showingOriginal: Bool, color: NSColor = .controlAccentColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium), text = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Translated")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(hierarchicalColor: color))) {
            let icon = NSTextAttachment(); icon.image = image
            icon.bounds = CGRect(x: 0, y: font.descender + 1, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: icon)); text.append(NSAttributedString(string: " "))
        }
        text.append(styled(translationLabel(translation, showingOriginal: showingOriginal), font, color, oneLine: true))
        return text
    }
    static func thinkingText(color: NSColor = .controlAccentColor) -> NSAttributedString {
        styled("Show thinking ›", .systemFont(ofSize: 12, weight: .medium), color, oneLine: true)
    }
    /// Up to three of the sources' kinds as icons, then "N Sources", as Google Chat heads the list.
    static func sourcesText(_ sources: [Source], color: NSColor = .controlAccentColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = NSMutableAttributedString()
        var kinds: [Source.Kind] = []
        for source in sources where !kinds.contains(source.kind) && kinds.count < 3 { kinds.append(source.kind) }
        for kind in kinds {
            let image = NSImage(systemSymbolName: symbol(kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color])))
            let icon = NSTextAttachment(); icon.image = image
            text.append(NSAttributedString(attachment: icon)); text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: sources.count == 1 ? "1 Source" : "\(sources.count) Sources"))
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }
    static func symbol(_ kind: Source.Kind) -> String {
        switch kind {
        case .gmail: "envelope.fill"
        case .calendar: "calendar"
        case .docs: "doc.text.fill"
        case .sheets: "tablecells.fill"
        case .slides: "rectangle.on.rectangle.angled.fill"
        case .drive: "folder.fill"
        case .youtube: "play.rectangle.fill"
        case .chat: "bubble.left.fill"
        case .tasks: "checkmark.circle.fill"
        case .web: "globe"
        }
    }
    static func retryText(color: NSColor = .systemRed) -> NSAttributedString {
        styled("Couldn’t send · Retry", .systemFont(ofSize: 11), color, oneLine: true)
    }
    /// A 1:1 DM has one reader: "Seen". Group DMs name them by first name.
    static func seenText(_ names: [String], kind: ConversationKind, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let first = names.map { String($0.split(separator: " ").first ?? Substring($0)) }
        return styled(kind == .direct ? "Seen" : "Seen by " + first.joined(separator: ", "), .systemFont(ofSize: 11), color)
    }
    static func serviceText(_ text: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(text, .systemFont(ofSize: 11, weight: .medium), color, alignment: .center)
    }
    static func styled(_ string: String, _ font: NSFont, _ color: NSColor = .labelColor, oneLine: Bool = false,
                       alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = oneLine ? .byTruncatingTail : .byWordWrapping
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    /// Options `TextLabel` draws with; measuring with the same ones keeps both in agreement.
    static let drawing: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
    /// A label's size wrapped at `width`, at most `lines` lines (0: no limit).
    static func measure(_ text: NSAttributedString, width: CGFloat, lines: Int = 0) -> CGSize {
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: drawing)
        var height = ceil(rect.height)
        if lines > 0, text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            height = min(height, ceil((font.ascender - font.descender + font.leading) * CGFloat(lines)))
        }
        return CGSize(width: min(width, ceil(rect.width)), height: height)
    }
}

final class MeasureTally: @unchecked Sendable {   // written only by the task that binds it
    var rows: [String] = [], texts = 0
}

private extension NSFont {
    var bold: NSFont { NSFont(descriptor: fontDescriptor.withSymbolicTraits(.bold), size: pointSize) ?? self }
}
