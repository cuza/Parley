import AppKit
import ParleyDomain

/// Computing a row's layout at one width.
extension RowLayout {
    // Phase 2 (PARLEY-193): one long pass over the row's parts, to be split into a function per part.
    /// Sender names show on the first bubble of a run in groups and spaces; avatars sit beside the run's last
    /// incoming bubble there (Telegram shows neither in one-to-one chats).
    /// `.plain` lays every message out as incoming in a space, with the avatar beside the run's first message.
    static func make(  // swiftlint:disable:this cyclomatic_complexity function_body_length
        _ row: TimelineRow, width: CGFloat, own: Bool, kind: ConversationKind,
        style: TimelineStyle = .bubbles
    ) -> RowLayout {
        let plain = style == .plain
        let readersKind = kind
        let own = own && !plain
        let kind: ConversationKind = plain ? .space : kind
        let message = row.message
        tally?.rows.append("\(row.id)@\(width)")
        var layout = RowLayout(width: width)
        var y: CGFloat = 0
        if row.newDay {
            let text = measure(dateText(message), width: width)  // a pill over a wallpaper, so it keeps the service inset
            let size = CGSize(width: text.width + 2 * serviceInset.width, height: text.height + 2 * serviceInset.height)
            layout.dateHeader = CGRect(
                x: ((width - size.width) / 2).rounded(), y: 9, width: size.width, height: size.height)
            y += size.height + 18
        }
        if message.isSystem {  // Telegram's service message: a small centered pill between bubbles
            let size = measure(
                serviceText(message.text), width: max(40, width - 2 * margin - 2 * serviceInset.width),
                lines: serviceLines)
            let pill = CGSize(width: size.width + 2 * serviceInset.width, height: size.height + 2 * serviceInset.height)
            layout.service = CGRect(
                x: ((width - pill.width) / 2).rounded(), y: y + 8, width: pill.width, height: pill.height)
            layout.height = ceil(y + 8 + pill.height + 8)
            return layout
        }
        y += row.begins ? 8 : 1

        let avatars = !own && kind != .direct
        let leading = margin + (avatars ? avatarSize + avatarGap : 0) + tailWidth
        let mediaOnly = Self.mediaOnly(message, style: style)
        let padX = mediaOnly ? 0 : Self.padX
        let padY = mediaOnly ? 0 : Self.padY  // pictures alone are flush
        let maxBubble = max(80, min(Self.maxBubble, width - leading - margin - tailWidth - 40))  // 40: a gutter on the far side
        // Pictures fill the bubble but for its 1 pt edge and set its width (the widest of them); text wraps within it.
        let flushMedia = Self.fillsBubble(message, style: style) ? message.attachments.filter(Self.isMedia) : []
        let caption = !message.text.isEmpty
        let mediaWidth: CGFloat? = flushMedia.map {
            Self.mediaSize($0, caption: caption, room: maxBubble - 2 * mediaInset).width
        }.max()
        let mediaBubble = mediaWidth.map { $0 + 2 * mediaInset }  // the bubble's width
        let inner = (mediaBubble ?? maxBubble) - 2 * padX

        // Content, laid out from the bubble's top-left; `lastLine` is how far a text-like last line reaches, for the time.
        // `afterPicture`: the last block is a flush picture, so what follows keeps a full padding from it.
        var cy = padY
        var contentWidth: CGFloat = 0
        var placed = false
        var afterPicture = false
        var lastLine: (width: CGFloat, bottom: CGFloat)?
        func place(_ size: CGSize) -> CGRect {
            if placed { cy += afterPicture ? mediaSpacing : spacing }
            placed = true
            afterPicture = false
            let rect = CGRect(x: padX, y: cy, width: size.width, height: size.height)
            cy += size.height
            contentWidth = max(contentWidth, size.width)
            return rect
        }
        // A message that is only cards has no bubble: its sender, badge and time make one line over the card, as Google
        // Chat draws it, in a DM too.
        let cardOnly =
            message.text.isEmpty && message.quote == nil && message.thinking.isEmpty && !message.attachments.isEmpty
            && message.attachments.allSatisfy { $0.card != nil }
        if !own
            && (row.begins && kind != .direct
                && !(style == .bubbles && message.attachments.contains(where: Self.isMedia)) || cardOnly)
        {  // as Telegram: no name on a picture, video or GIF
            var name = measure(nameText(message.sender.name), width: inner)
            if let via = message.via {  // the name gives way to the badge, which keeps its size
                let text = measure(viaText(via), width: inner / 2)
                let badge = CGSize(width: text.width + 2 * viaInset.width, height: text.height + 2 * viaInset.height)
                name.width = min(name.width, max(0, inner - viaGap - badge.width))
                let line = place(
                    CGSize(width: name.width + viaGap + badge.width, height: max(name.height, badge.height)))
                layout.name = CGRect(
                    x: line.minX, y: line.minY + ((line.height - name.height) / 2).rounded(), width: name.width,
                    height: name.height)
                layout.via = CGRect(
                    x: line.minX + name.width + viaGap, y: line.minY + ((line.height - badge.height) / 2).rounded(),
                    width: badge.width, height: badge.height)
            } else {
                layout.name = place(name)
            }
            let line = layout.name.map {
                CGRect(
                    x: $0.minX, y: $0.minY, width: (layout.via?.maxX ?? $0.maxX) - $0.minX,
                    height: max($0.height, layout.via?.height ?? 0))
            }
            lastLine = cardOnly ? line.map { ($0.width, $0.maxY) } : nil  // the time follows the name
        }
        if !message.thinking.isEmpty {
            layout.thinking = place(measure(thinkingText(), width: inner))
            lastLine = nil
        }
        if let quote = message.quote {
            let textWidth = inner - quoteBar - 15
            let sender = measure(quoteSenderText(quote), width: textWidth)
            let body = measure(quoteBodyText(quote), width: textWidth, lines: 2)
            let block = place(
                CGSize(
                    width: min(inner, max(sender.width, body.width) + quoteBar + 15),
                    height: sender.height + body.height + 8))
            layout.quote = block
            layout.quoteSender = CGRect(
                x: block.minX + quoteBar + 7, y: block.minY + 4, width: sender.width, height: sender.height)
            layout.quoteText = CGRect(
                x: block.minX + quoteBar + 7, y: block.minY + 4 + sender.height, width: body.width, height: body.height)
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
            if attachment.card != nil {  // placed under the bubble, below
                cards.append(
                    (index, attachmentSize(attachment, maxWidth: maxBubble, transcriptOpen: row.transcriptOpen)))
                layout.attachments.append(.zero)
                continue
            }
            if let mediaWidth, Self.isMedia(attachment) {  // the bubble's width but for its edge; a narrower one has a blur at its sides
                let size = Self.mediaSize(attachment, caption: caption, room: maxBubble - 2 * mediaInset)
                cy = !placed ? mediaInset : cy + (afterPicture ? mediaGap : mediaSpacing)
                layout.attachments.append(CGRect(x: mediaInset, y: cy, width: mediaWidth, height: size.height))
                cy += size.height
                placed = true
                afterPicture = true
                lastLine = nil
                continue
            }
            let size =
                mediaOnly && Self.isMedia(attachment)
                ? Self.mediaSize(attachment, caption: false, room: inner)
                : attachmentSize(attachment, maxWidth: inner, transcriptOpen: row.transcriptOpen)
            let rect = place(size)
            layout.attachments.append(rect)
            // A voice message's time sits level with its duration, as Telegram's does (room left for the speed toggle).
            lastLine =
                attachment.kind == .voice && attachment.voice?.transcript == nil
                ? (VoiceLayout.button + VoiceLayout.gap + 70, rect.maxY) : nil
        }
        if !flushMedia.isEmpty { placeText() }
        if !message.sources.isEmpty {
            let rect = place(measure(sourcesText(message.sources), width: inner))
            layout.sources = rect
            lastLine = (rect.width, rect.maxY)
        }
        let pillOnPicture = Self.timeOnPicture(message, style: style) && !row.draft
        let lastMedia = pillOnPicture ? layout.attachments.last : nil
        // Reactions under a bubble that ends with a picture go outside it, the time staying on the picture (Telegram's).
        layout.reactionsOutside = pillOnPicture && !message.reactions.isEmpty
        if !message.reactions.isEmpty && !layout.reactionsOutside {
            if placed { cy += afterPicture ? mediaSpacing : spacing }
            placed = true
            afterPicture = false
            let flow = reactionFlow(message.reactions, width: inner)
            layout.reactions = flow.pills.map { $0.offsetBy(dx: padX, dy: cy) }
            contentWidth = max(contentWidth, flow.size.width)
            cy += flow.size.height
            lastLine = (flow.lastLine, cy)
        }
        if message.replyCount > 0 || row.draft {
            let rect = place(measure(repliesText(message.replyCount, draft: row.draft), width: inner))
            layout.replies = rect
            lastLine = (rect.width, rect.maxY)
        }
        // The time sits after the last line when it fits there (Telegram's inline date), else on a line of its own.
        var time = measure(timeText(message), width: inner)
        if let lastMedia, time.width + 2 * mediaPillInset.width + 2 * mediaPillMargin.width > lastMedia.width {
            layout.timeOnly = true
            time = measure(timeText(message, timeOnly: true), width: inner)
        }
        var timeTop: CGFloat = 0
        if pillOnPicture {  // on a pill over the last picture's corner: takes no room
        } else if let lastLine, lastLine.width + timeGap + time.width <= inner {
            timeTop = lastLine.bottom - time.height
            contentWidth = max(contentWidth, lastLine.width + timeGap + time.width)
        } else {
            timeTop = placed ? cy + (afterPicture ? mediaSpacing : 2) : cy
            cy = timeTop + time.height
            contentWidth = max(contentWidth, time.width)
        }
        cy += lastMedia == nil ? padY : mediaWidth == nil ? 0 : mediaInset  // a picture with the time on it ends the bubble, but for its edge

        if mediaWidth != nil { contentWidth = inner }
        let bubbleWidth = mediaBubble ?? contentWidth + 2 * padX
        let bubble = CGRect(
            x: own ? width - margin - tailWidth - bubbleWidth : leading, y: y, width: bubbleWidth, height: cy)
        layout.bubble = bubble
        layout.tail = row.ends && !plain && !mediaOnly  // beside a picture too: it grows from the bubble's edge, outside the picture
        layout.time = CGRect(
            x: bubble.maxX - padX - time.width, y: bubble.minY + timeTop, width: time.width, height: time.height)
        layout.bare = message.jumboEmoji != nil || cardOnly || mediaOnly
        layout.mediaOnly = mediaOnly
        if let lastMedia {
            let pill = CGSize(
                width: time.width + 2 * mediaPillInset.width, height: time.height + 2 * mediaPillInset.height)
            layout.time = CGRect(
                x: bubble.minX + max(lastMedia.minX, lastMedia.maxX - mediaPillMargin.width - pill.width),
                y: bubble.minY + lastMedia.maxY - mediaPillMargin.height - pill.height,
                width: pill.width, height: pill.height)
        }
        if message.jumboEmoji != nil {
            layout.time = layout.time.insetBy(dx: -jumboTimeInset.width, dy: -jumboTimeInset.height)
        }  // room for the pill
        let offset = { (rect: CGRect) in rect.offsetBy(dx: bubble.minX, dy: bubble.minY) }
        layout.name = layout.name.map(offset)
        layout.via = layout.via.map(offset)
        layout.quote = layout.quote.map(offset)
        layout.quoteSender = layout.quoteSender.map(offset)
        layout.quoteText = layout.quoteText.map(offset)
        // As wide as the content (wraps the same: every measured line still fits), so code-block backgrounds fill the bubble.
        layout.text = layout.text.map {
            offset(CGRect(x: $0.minX, y: $0.minY, width: min(contentWidth, inner), height: $0.height))
        }
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
        if layout.reactionsOutside {  // 4 pt under the bubble, on the sender's side
            let flow = reactionFlow(message.reactions, width: maxBubble)
            let x = own ? bubble.maxX - flow.size.width : bubble.minX
            layout.reactions = flow.pills.map { $0.offsetBy(dx: x, dy: y + 4) }
            y += 4 + flow.size.height
        }
        // A translated message's toggle sits under the bubble, on the sender's side, as Google Chat draws it.
        if let translation = message.translation {
            let size = measure(translationText(translation, showingOriginal: row.transcriptOpen), width: maxBubble)
            layout.translation = CGRect(
                x: own ? bubble.maxX - size.width : bubble.minX, y: y + 3, width: size.width, height: size.height)
            y += size.height + 3
        }
        // An app's card stands on its own under the bubble, as Google Chat draws it, on the sender's side.
        for card in cards {
            y += spacing
            layout.attachments[card.index] = CGRect(
                x: own ? bubble.maxX - card.size.width : bubble.minX, y: y, width: card.size.width,
                height: card.size.height)
            y += card.size.height
        }
        let bottom = y
        if message.delivery == .failed {
            let size = measure(retryText(), width: maxBubble)
            layout.retry = CGRect(
                x: own ? bubble.maxX - size.width : bubble.minX, y: y + 3, width: size.width, height: size.height)
            y += size.height + 3
        }
        if !row.seenBy.isEmpty {
            let size = measure(seenText(row.seenBy, kind: readersKind), width: maxBubble)
            layout.seen = CGRect(
                x: own ? bubble.maxX - size.width : bubble.minX, y: y + 2, width: size.width, height: size.height)
            y += size.height + 2
        }
        if plain && row.begins {
            layout.avatar = CGRect(x: margin, y: bubble.minY + 2, width: avatarSize, height: avatarSize)
        } else if !plain && avatars && row.ends {
            layout.avatar = CGRect(x: margin, y: bottom - avatarSize, width: avatarSize, height: avatarSize)
        }
        layout.height = ceil(y + 1)
        return layout
    }

    /// Reaction pills flowed onto lines `width` wide, from the origin: their frames, the block's size, the last line's width.
    private static func reactionFlow(_ reactions: [Reaction], width: CGFloat) -> (
        pills: [CGRect], size: CGSize, lastLine: CGFloat
    ) {
        var pills: [CGRect] = []
        var x: CGFloat = 0
        var lineTop: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for reaction in reactions {
            let text = measure(pillText(reaction), width: width)
            let pill = CGSize(width: text.width + 2 * pillInset.width, height: text.height + 2 * pillInset.height)
            if x > 0 && x + pill.width > width {
                x = 0
                lineTop += lineHeight + spacing
                lineHeight = 0
            }
            pills.append(CGRect(x: x, y: lineTop, width: pill.width, height: pill.height))
            x += pill.width + spacing
            lineHeight = max(lineHeight, pill.height)
            widest = max(widest, x - spacing)
        }
        return (pills, CGSize(width: widest, height: lineTop + lineHeight), x - spacing)
    }
}
