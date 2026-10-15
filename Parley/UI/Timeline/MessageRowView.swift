import AppKit
import SwiftUI

/// What a row can ask for; the table owner supplies these, so the row never holds the store.
struct MessageRowActions {
    var react: (String, Message) -> Void = { _, _ in }
    var toggleTranscript: (Message) -> Void = { _ in }
    var dismissCard: (Message) -> Void = { _ in }
    var clickCard: (Message, String?, Data, [Card.Input]) async -> Void = { _, _, _, _ in }   // a card button's action   // a card's dismiss button (an app suggestion's "Don't install")
    var reactCustom: (CustomEmoji, Message) -> Void = { _, _ in }
    /// The organisation's custom emoji, which the picker offers; nil: none.
    var customEmoji: (() async -> [CustomEmoji])? = nil
    /// Who reacted, "Alice and You", for a reaction pill's hover card; nil: keep the count.
    var reactors: (Reaction, Message) async -> String? = { _, _ in nil }
    var openThread: (Message) -> Void = { _ in }
    var quote: (Message) -> Void = { _ in }   // a quote reply from this message's composer
    var forward: ((Message) -> Void)? = nil   // Forward…: pick where it goes; nil: not offered
    var showQuoted: (MessageID) -> Void = { _ in }   // a click on a quote: go to the message it quotes
    var message: ((Person) -> Void)? = nil    // "Message <Name>" from a sender's avatar or name, or a mention; nil: not offered
    var person: (PersonID) -> Person? = { _ in nil }   // who a mention names, for its card
    /// A Google Chat link in the text (a message link or a space chip); by default it opens in the browser.
    /// Opens a Google Chat link in Parley; false when the account doesn't have the conversation.
    var openChatLink: (ChatLink, URL) async -> Bool = { _, url in NSWorkspace.shared.open(url) }
    var retry: (Message) -> Void = { _ in }
    var copy: (Message) -> Void = { message in
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
    }
    var edit: (Message) -> Void = { _ in }
    var delete: (Message) -> Void = { _ in }
    /// Star or unstar (the new state); nil: not offered.
    var star: ((Bool, Message) -> Void)? = nil
    /// Pin to the board or unpin (the new state); nil: not offered.
    var pin: ((Bool, Message) -> Void)? = nil
    var markUnread: ((Message) -> Void)? = nil   // Mark as Unread from this message on; nil: not offered
    var report: ((Message) -> Void)? = nil   // Report this message (Workspace); nil: not offered
    /// Names of everyone whose read receipt covers the message, for "Seen by …" on my messages.
    var readers: (Message) -> [String] = { _ in [] }
    var loadAttachment: (Attachment, _ thumbnail: Bool) async throws -> Data = { _, _ in throw CancellationError() }
    /// Quick Look, drag out, and the attachment menu items; set by the table (`MessageTable`).
    var files: AttachmentFiles?
    /// Counts reactions made from the menu and the picker, which then offer the most used first; nil: the defaults.
    var emojiUsage: EmojiUsage?
}

/// One message in the timeline, as AppKit views placed by frame from its `RowLayout`:
/// no Auto Layout, and the only hosted SwiftUI (avatar, attachments) gets a fixed frame it never sizes itself.
/// Reusable: `configure` again with another row. When the row's width changes, `layout()` recomputes the layout.
final class MessageRowView: NSTableRowView {
    private(set) var row: TimelineRow?
    private(set) var rowLayout: RowLayout?
    private var timeOnly = false
    /// Where a timeline's row view gets its layout when its width changes: the table's cache. Without one, it measures.
    var layoutFor: (@MainActor (TimelineRow) -> RowLayout?)?
    private(set) var style = TimelineStyle.bubbles
    private var own = false
    private var kind = ConversationKind.direct
    private var actions = MessageRowActions()
    private var meID = ""
    private var highlighted = false
    private var pictures = false   // the time is on a pill over the last picture

    let dateLabel = TextLabel()
    let avatarView = AvatarHostView(rootView: Avatar(name: "", size: RowLayout.avatarSize))
    let bubbleView = BubbleView()
    let nameLabel = TextLabel()
    let viaLabel = TextLabel()   // the app that posted for the sender, after the name
    let quoteView = QuoteView()
    let quoteSenderLabel = TextLabel()
    let quoteTextLabel = TextLabel()
    /// Revealed at the right edge while the row is swiped toward reply (`setSwipe`): the quote arrow, or the thread icon
    /// once the swipe reaches the thread stage.
    let replyArrow = NSImageView(image: MessageRowView.quoteIcon)
    private static let quoteIcon = NSImage(systemSymbolName: "arrowshape.turn.up.left.circle.fill", accessibilityDescription: "Reply") ?? NSImage()
    private static let threadIcon = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Reply in Thread") ?? NSImage()
    let textView: MessageTextView = {   // TextKit 1, as `MessageTextStyle.measure`; rounded backgrounds, as chips need
        let view = MessageTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(MessageLayoutManager())
        return view
    }()
    private(set) var attachmentViews: [AttachmentHostView] = []
    private(set) var reactionPills: [TextLabel] = []
    private var emojiTask: Task<Void, Never>?
    let repliesLink = TextLabel()
    let sourcesLink = TextLabel()   // a Gemini answer's "N Sources": a click lists them
    let translationLink = TextLabel()   // a translated message's "View original (…)" / "Show translation"
    let thinkingLink = TextLabel()  // a Gemini answer's "Show thinking": a click shows its steps
    let timeLabel = TextLabel()
    let retryLink = TextLabel()
    let serviceLabel = TextLabel()   // a system event's pill, instead of the bubble
    let seenLabel = TextLabel()
    /// Behind the time on a picture: the picture blurred under the pill (Telegram's), made when a row first needs one.
    private var pillBlur: NSVisualEffectView?
    /// A jump to this message: the whole row flashes, as Telegram's does, over the picture too.
    let flash = CALayer()
    /// Beside the last reaction pill while the pointer is over the row: opens the emoji picker (Slack's "add reaction").
    /// Made on the first hover: most rows are never hovered, and a button was most of what a new row cost.
    private(set) lazy var addReactionButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Add Reaction") ?? NSImage(),
                              target: self, action: #selector(showEmojiPicker))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Add Reaction"
        button.wantsLayer = true
        button.autoresizingMask = []
        addSubview(button)
        madeAddReaction = true
        return button
    }()
    private var madeAddReaction = false
    private var hovering = false { didSet { if hovering != oldValue { needsLayout = true } } }
    private var hoverArea: NSTrackingArea?
    private var emojiPicker: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
        avatarView.sizingOptions = []
        replyArrow.contentTintColor = .controlAccentColor
        replyArrow.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        replyArrow.alphaValue = 0
        addSubview(replyArrow)
        textView.isEditable = false; textView.isSelectable = true
        // macOS otherwise draws a Siri / Writing Tools badge on the bubble; message text is read-only.
        if #available(macOS 15.2, *) { textView.writingToolsBehavior = .none }
        textView.messageMenu = { [weak self] selection in self?.hasActions == true ? self?.contextMenu(selection: selection) : nil }
        textView.mentionMenu = { [weak self] id, name in self?.mentionMenu(id, name: name) }
        textView.openChatLink = { [weak self] link, url in await self?.actions.openChatLink(link, url) ?? true }
        textView.loadAttachment = { [weak self] in try await (self?.actions.loadAttachment ?? { _, _ in throw CancellationError() })($0, $1) }
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false; textView.isHorizontallyResizable = false
        serviceLabel.inset = RowLayout.serviceInset
        viaLabel.background = .labelColor.withAlphaComponent(0.08)
        viaLabel.inset = RowLayout.viaInset
        wantsLayer = true
        flash.backgroundColor = NSColor.controlAccentColor.cgColor   // set again as it flashes, for the current accent
        flash.opacity = 0; flash.zPosition = 10
        layer?.addSublayer(flash)
        for view: NSView in [dateLabel, avatarView, bubbleView, quoteView, quoteSenderLabel, quoteTextLabel, nameLabel, viaLabel, textView, repliesLink, sourcesLink, translationLink, thinkingLink, timeLabel, retryLink, serviceLabel, seenLabel] {
            view.autoresizingMask = []
            addSubview(view)
        }
    }
    convenience init() { self.init(frame: .zero) }
    /// Swipe to reply (Telegram's reveal): the content slides left by `-offset` and the reply arrow fades in at the
    /// right edge, fully opaque once a stage is armed; at the thread stage it becomes the thread icon.
    func setSwipe(offset: CGFloat, stage: ReplySwipe.Stage?) {
        let shift = max(0, -offset)
        bounds.origin.x = shift
        let icon = stage == .thread ? Self.threadIcon : Self.quoteIcon
        if replyArrow.image !== icon { replyArrow.image = icon }
        replyArrow.alphaValue = shift == 0 ? 0 : stage != nil ? 1 : min(0.95, shift / ReplySwipe.threshold)
        placeReplyArrow()
    }
    private func placeReplyArrow() {
        let size: CGFloat = 26
        replyArrow.frame = NSRect(x: bounds.maxX - size - 10, y: (bounds.height - size) / 2, width: size, height: size)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Shows `row`. Pass `layout` when it was already computed for this row at the row view's width (the table's
    /// height cache); otherwise it is computed at the next `layout()`.
    /// The row as VoiceOver reads it: the day when it starts one, who, the quote, the text, attachments, the time, and its
    /// state (edited, sending, not sent, seen by).
    /// Where Copy writes; tests use their own.
    static var pasteboard = NSPasteboard.general
    /// The message as shown, as rich text (links, bold, lists) for Mail and Notes and plain text for the rest. The bubble's
    /// colours stay behind: pasted, they'd be the bubble's, not the document's.
    static func copy(_ rich: NSAttributedString) {
        let clean = NSMutableAttributedString(attributedString: rich), all = NSRange(location: 0, length: clean.length)
        clean.removeAttribute(.foregroundColor, range: all); clean.removeAttribute(.backgroundColor, range: all)
        pasteboard.clearContents()
        pasteboard.writeObjects([clean])
    }
    static func spoken(_ row: TimelineRow, own: Bool) -> String {
        let message = row.message
        var parts: [String] = []
        if row.newDay { parts.append(message.createdAt.formatted(date: .complete, time: .omitted)) }
        if !message.isSystem { parts.append(own ? "You" : message.sender.name) }
        if let quote = message.quote { parts.append("replying to \(quote.sender): \(quote.text)") }
        let text = TextStyleRange.plain(message.text, message.formatting)
        if !text.isEmpty { parts.append(text) }
        parts += message.attachments.map(\.name).filter { !$0.isEmpty }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        if message.edited { parts.append("edited") }
        switch message.delivery {
        case .pending: parts.append("sending")
        case .failed: parts.append("not sent")
        case .sent: break
        }
        if !row.seenBy.isEmpty { parts.append("seen by " + row.seenBy.formatted(.list(type: .and))) }
        return parts.joined(separator: ", ")
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        contextMenu().items.compactMap { $0 as? ClosureMenuItem }.filter(\.isEnabled).map { item in
            NSAccessibilityCustomAction(name: item.title) { item.handler(); return true }
        }
    }
    func configure(_ row: TimelineRow, own: Bool, kind: ConversationKind, meID: String, layout: RowLayout? = nil,
                   highlighted: Bool = false, style: TimelineStyle = .bubbles, actions: MessageRowActions) {
        let own = own && style == .bubbles   // plain shows everyone like an incoming message
        let pictures = RowLayout.timeOnPicture(row.message, style: style) && !row.draft   // the time is on a pill over the last picture
        self.pictures = pictures
        let flashes = highlighted && !(self.highlighted && self.row?.id == row.id)   // newly jumped to
        if self.row?.id != row.id { flash.removeAnimation(forKey: "flash") }
        let lone = RowLayout.mediaOnly(row.message, style: style)   // no bubble: what sits under the pictures is not on mine
        if style != self.style { rowLayout = layout; self.style = style }
        let message = row.message
        if row != self.row || own != self.own || kind != self.kind { rowLayout = layout }
        else if let layout { rowLayout = layout }
        self.row = row; self.own = own; self.kind = kind; self.actions = actions
        self.meID = meID
        // VoiceOver reads the row as one line; its actions are the menu's (built only when VoiceOver asks). The row stays a
        // container, so the text inside (its links, a selection) can still be reached.
        setAccessibilityLabel(Self.spoken(row, own: own))
        let ink = BubblePalette.ownInk, accent = BubblePalette.ownAccent
        let secondary: NSColor = own && !lone ? accent.withAlphaComponent(0.75) : .secondaryLabelColor
        let senderColor = Self.color(for: message.sender.id)

        dateLabel.text = RowLayout.dateText(message, color: BubblePalette.serviceText)
        dateLabel.background = BubblePalette.servicePill
        dateLabel.inset = RowLayout.serviceInset
        // Only when it changes: a SwiftUI update (and its image task) on every row reused while scrolling adds up.
        if avatarView.rootView.name != message.sender.name || avatarView.rootView.url != message.sender.avatarURL {
            avatarView.rootView = Avatar(name: message.sender.name, size: RowLayout.avatarSize, url: message.sender.avatarURL)
        }
        bubbleView.fill = lone ? .clear : own ? BubblePalette.own : BubblePalette.incoming; bubbleView.own = own
        if flashes { flashRow() }
        self.highlighted = highlighted
        nameLabel.text = RowLayout.nameText(message.sender.name, color: senderColor)
        viaLabel.text = RowLayout.viaText(message.via ?? "")
        // Only an app that posted for a person says so; "App" and "Only visible to you" say it themselves.
        let acting = message.via?.components(separatedBy: " · ").first { $0 != "App" && $0 != "Only visible to you" }
        viaLabel.toolTip = acting.map { "Posted by \($0) on \(message.sender.name)’s behalf" }
        if let quote = message.quote {
            let quoteColor = own ? accent : Self.color(for: quote.sender)
            quoteView.bar = quoteColor
            quoteView.fill = own ? accent.withAlphaComponent(0.2) : quoteColor.withAlphaComponent(0.1)
            quoteView.onClick = quote.id.map { id in { [weak self] in self?.actions.showQuoted(id) } }
            quoteSenderLabel.text = RowLayout.quoteSenderText(quote, color: quoteColor)
            quoteTextLabel.text = RowLayout.quoteBodyText(quote, color: own ? ink.withAlphaComponent(0.85) : .secondaryLabelColor)
        }
        NativeMessageText.show(message.text, formatting: message.formatting, own: own, jumbo: message.jumboEmoji, in: textView)
        // Links on my bubble take its accent, as Telegram draws them; elsewhere the system link colour.
        textView.linkTextAttributes = [.foregroundColor: own ? accent : .linkColor,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]

        while attachmentViews.count > message.attachments.count { attachmentViews.removeLast().removeFromSuperview() }
        for (index, attachment) in message.attachments.enumerated() {
            let content = AttachmentView(attachment: attachment, load: actions.loadAttachment, own: own, transcriptOpen: row.transcriptOpen,
                                         toggleTranscript: { [weak self] in self?.actions.toggleTranscript(message) },
                                         dismissCard: { [weak self] in self?.actions.dismissCard(message) },
                                         clickCard: { [weak self] card, action, inputs in await self?.actions.clickCard(message, card, action, inputs) })
            if index < attachmentViews.count { attachmentViews[index].rootView = content }
            else {
                let host = AttachmentHostView(rootView: content)
                host.sizingOptions = []; host.autoresizingMask = []
                addSubview(host, positioned: .below, relativeTo: timeLabel)
                attachmentViews.append(host)
            }
            attachmentViews[index].attachment = attachment
            attachmentViews[index].files = actions.files
        }

        while reactionPills.count > message.reactions.count { reactionPills.removeLast().removeFromSuperview() }
        while reactionPills.count < message.reactions.count {
            let pill = TextLabel(); pill.autoresizingMask = []
            addSubview(pill, positioned: .below, relativeTo: timeLabel)
            reactionPills.append(pill)
        }
        for (pill, reaction) in zip(reactionPills, message.reactions) {
            let mine = reaction.people.contains(meID)
            let onMine = own && !lone && !pictures   // under a picture's bubble, reactions sit outside it
            pill.text = RowLayout.pillText(reaction, color: onMine ? ink : .labelColor)
            pill.background = onMine ? ink.withAlphaComponent(mine ? 0.35 : 0.2)
                : mine ? .controlAccentColor.withAlphaComponent(0.18) : .labelColor.withAlphaComponent(0.07)
            pill.inset = NSSize(width: 7, height: 3)
            pill.onClick = { [weak self, weak pill] in ReactionCard.shared.hide(pill); self?.actions.react(reaction.emoji, message) }
            pill.setAccessibilityLabel("\(reaction.emoji) \(reaction.people.count)")
            // Names are looked up when the pointer reaches the pill, so they are usually in before the card shows.
            pill.onHover = { [weak self, weak pill] in
                guard let self, let pill else { return }
                var card = ReactionCardView(reaction: reaction, names: ChatStore.reactorsLine(names: [], count: reaction.people.count),
                                            load: actions.loadAttachment)
                ReactionCard.shared.hover(pill, card)
                Task {
                    guard let line = await self.actions.reactors(reaction, message),
                          self.row?.message.id == message.id, self.row?.message.reactions.contains(reaction) == true else { return }
                    card.names = line
                    ReactionCard.shared.update(pill, card)
                }
            }
            pill.onExit = { [weak pill] in ReactionCard.shared.hide(pill) }
        }
        loadCustomEmoji(message)
        repliesLink.text = RowLayout.repliesText(message.replyCount, draft: row.draft, color: own && !lone ? ink : .controlAccentColor)
        repliesLink.onClick = { [weak self] in self?.actions.openThread(message) }
        sourcesLink.text = message.sources.isEmpty ? NSAttributedString() : RowLayout.sourcesText(message.sources, color: own ? ink : .controlAccentColor)
        translationLink.text = message.translation.map { RowLayout.translationText($0, showingOriginal: row.transcriptOpen) } ?? NSAttributedString()   // under the bubble: the accent colour
        translationLink.onClick = message.translation == nil ? nil : { [weak self] in self?.actions.toggleTranscript(message) }
        thinkingLink.text = message.thinking.isEmpty ? NSAttributedString() : RowLayout.thinkingText(color: own ? ink : .controlAccentColor)
        thinkingLink.onClick = { [weak self] in
            guard let self else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: ThinkingView(steps: message.thinking))
            popover.show(relativeTo: thinkingLink.bounds, of: thinkingLink, preferredEdge: .maxY)
        }
        sourcesLink.onClick = { [weak self] in
            guard let self else { return }
            Self.sourcesMenu(message.sources) { [weak self] url in
                Self.open(source: url, chatLink: { link, url in
                    guard let self, let window = self.window else { return }
                    let screen = window.convertToScreen(self.sourcesLink.convert(self.sourcesLink.bounds, to: nil))
                    Task { [weak self] in
                        guard let self, await !self.actions.openChatLink(link, url) else { return }
                        ChatLink.showRestricted(link, above: screen, in: window)
                    }
                }, browser: { NSWorkspace.shared.open($0) })
            }
                .popUp(positioning: nil, at: NSPoint(x: 0, y: sourcesLink.bounds.maxY + 4), in: sourcesLink)
        }
        let bare = message.jumboEmoji != nil   // large emoji: the time sits on a pill, as on a service line
        timeOnly = false
        timeLabel.text = RowLayout.timeText(message, color: pictures ? .white : bare ? BubblePalette.serviceText : secondary)
        timeLabel.background = pictures ? BubblePalette.mediaPill : bare ? BubblePalette.timePill : nil
        timeLabel.inset = pictures ? RowLayout.mediaPillInset : bare ? NSSize(width: RowLayout.serviceInset.width / 2, height: RowLayout.serviceInset.height / 2) : .zero
        retryLink.text = RowLayout.retryText()
        retryLink.onClick = { [weak self] in self?.actions.retry(message) }
        serviceLabel.text = message.isSystem ? RowLayout.serviceText(message.text, color: BubblePalette.serviceText) : NSAttributedString()
        serviceLabel.background = Wallpaper.current(dark: effectiveAppearance.isDark) == .none ? .labelColor.withAlphaComponent(0.06) : BubblePalette.servicePill
        serviceLabel.toolTip = message.isSystem ? message.text : nil
        seenLabel.text = RowLayout.seenText(row.seenBy, kind: kind)

        setAccessibilityIdentifier(message.id)
        timeLabel.toolTip = message.createdAt.formatted(date: .complete, time: .standard)   // on the time only: a row-wide one gets in the way
        needsLayout = true
    }

    override func layout() {
        placeReplyArrow()
        super.layout()
        guard let row else { return }
        if rowLayout?.width != bounds.width {
            rowLayout = layoutFor.map { $0(row) ?? rowLayout } ?? RowLayout.make(row, width: bounds.width, own: own, kind: kind, style: style)
        }
        guard let layout = rowLayout else { return }
        if layout.timeOnly != timeOnly, let message = self.row?.message {   // a picture too narrow for the pill's extras
            timeOnly = layout.timeOnly
            timeLabel.text = RowLayout.timeText(message, color: .white, timeOnly: timeOnly)
        }
        place(dateLabel, layout.dateHeader)
        place(avatarView, layout.avatar)
        // The bubble view also holds the tail, on the sender's side; the shape decides whether to draw it.
        place(bubbleView, CGRect(x: layout.bubble.minX - (own ? 0 : RowLayout.tailWidth), y: layout.bubble.minY,
                                 width: layout.bubble.width + RowLayout.tailWidth, height: layout.bubble.height))
        // Plain, service lines, large emoji and lone pictures draw none.
        bubbleView.tail = layout.tail
        bubbleView.isHidden = style == .plain || layout.service != nil || layout.bare
        place(serviceLabel, layout.service)
        place(nameLabel, layout.name)
        place(viaLabel, layout.via)
        place(quoteView, layout.quote)
        place(quoteSenderLabel, layout.quoteSender)
        place(quoteTextLabel, layout.quoteText)
        place(textView, layout.text)
        for (view, frame) in zip(attachmentViews, layout.attachments) { place(view, frame) }
        // A picture flush in the bubble is clipped by the bubble's rounded corners (a layout's, as the row is measured).
        for (view, corners) in zip(attachmentViews, layout.attachmentCorners) where view.rootView.corners != corners { view.rootView.corners = corners }
        for (view, frame) in zip(reactionPills, layout.reactions) { place(view, frame) }
        place(repliesLink, layout.replies)
        place(sourcesLink, layout.sources)
        place(translationLink, layout.translation)
        place(thinkingLink, layout.thinking)
        place(timeLabel, layout.service == nil ? layout.time : nil)
        if pictures && layout.service == nil { placePillBlur(layout.time) } else if let pillBlur { place(pillBlur, nil) }
        CATransaction.begin(); CATransaction.setDisableActions(true); flash.frame = bounds; CATransaction.commit()
        place(retryLink, layout.retry)
        place(seenLabel, layout.seen)
        if hovering, let frame = addReactionFrame(layout) { place(addReactionButton, frame) }
        else if madeAddReaction { place(addReactionButton, nil) }
    }
    /// Outside the bubble, level with the last pill, on the side away from the sender's tail.
    /// Custom emoji draw a placeholder until `ImageCache` has their picture; this fetches the missing ones, then redraws.
    private func loadCustomEmoji(_ message: Message) {
        let text = (message.formatting + (message.quote?.emoji ?? [])).compactMap { range -> CustomEmoji? in if case .customEmoji(let emoji) = range.style { emoji } else { nil } }
        let pictures = Set((text + message.reactions.compactMap(\.custom)).compactMap(\.image).filter { ImageCache.cached($0) == nil })
        emojiTask?.cancel()
        guard !pictures.isEmpty else { return }
        let load = actions.loadAttachment
        emojiTask = Task { [weak self] in
            for picture in pictures { _ = try? await ImageCache.load(picture, load) }
            guard let self, !Task.isCancelled else { return }
            textView.needsDisplay = true
            quoteTextLabel.needsDisplay = true
            reactionPills.forEach { $0.needsDisplay = true }
        }
    }
    private func addReactionFrame(_ layout: RowLayout) -> CGRect? {
        guard let last = layout.reactions.last else { return nil }
        let width = last.height + 10
        addReactionButton.layer?.cornerRadius = last.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            addReactionButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
        return CGRect(x: own ? layout.bubble.minX - 6 - width : layout.bubble.maxX + RowLayout.tailWidth + 6, y: last.minY, width: width, height: last.height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hovering = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovering = false }
    private func placePillBlur(_ frame: CGRect) {
        let blur = pillBlur ?? {
            let view = NSVisualEffectView()
            view.blendingMode = .withinWindow; view.state = .active; view.material = .hudWindow
            view.wantsLayer = true; view.layer?.masksToBounds = true; view.autoresizingMask = []
            pillBlur = view
            return view
        }()
        // Above the pictures (added under the time as they come), right under the time.
        if let index = subviews.firstIndex(of: timeLabel), index == 0 || subviews[index - 1] !== blur { addSubview(blur, positioned: .below, relativeTo: timeLabel) }
        place(blur, frame)
        blur.layer?.cornerRadius = frame.height / 2
    }
    /// Telegram's jump flash: the row tints to half its blue and back.
    private func flashRow() {
        effectiveAppearance.performAsCurrentDrawingAppearance { flash.backgroundColor = NSColor.controlAccentColor.cgColor }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.5, 0.5, 0]; fade.keyTimes = [0, 0.15, 0.55, 1]; fade.duration = 1.5
        flash.add(fade, forKey: "flash")
    }
    private func place(_ view: NSView, _ frame: CGRect?) {
        view.isHidden = frame == nil
        if let frame, view.frame != frame { view.frame = frame }
    }

    override func menu(for event: NSEvent) -> NSMenu? { hasActions ? contextMenu() : nil }
    /// A service line and a deleted message offer no actions, as on the web: nothing to quote, react to or forward.
    private var hasActions: Bool { row.map { !$0.message.isSystem && !$0.message.tombstone } ?? false }
    /// A click or right-click on the sender's avatar or name offers to message them.
    override func mouseDown(with event: NSEvent) {
        if !popUpPersonMenu(event) { super.mouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !popUpPersonMenu(event) { super.rightMouseDown(with: event) }
    }
    private func popUpPersonMenu(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard [avatarView, nameLabel].contains(where: { !$0.isHidden && $0.frame.contains(point) }), let menu = personMenu() else { return false }
        menu.popUp(positioning: nil, at: point, in: self)
        return true
    }
    /// The sender's photo, name and email, and "Message <Name>": in group DMs and spaces, never for me.
    func personMenu() -> NSMenu? {
        guard let person = row?.message.sender, row?.message.isSystem == false else { return nil }
        return personMenu(person)
    }
    /// The same card for a mention in the text; `name`: the mention's text, for someone the conversation doesn't know.
    func mentionMenu(_ id: PersonID, name: String) -> NSMenu? {
        personMenu(actions.person(id) ?? Person(id: id, name: name))
    }
    private func personMenu(_ person: Person) -> NSMenu? {
        guard kind != .direct, person.id != meID, let message = actions.message else { return nil }
        let menu = NSMenu()
        let card = NSMenuItem()
        let host = NSHostingView(rootView: PersonCard(person: person))
        host.frame.size = host.fittingSize
        card.view = host
        menu.addItem(card)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Message \(person.name)") { message(person) })
        return menu
    }
    /// Right-click, as in Telegram and iMessage: a strip of quick reactions, then the message actions.
    /// `selection`: text selected in the bubble, which Copy then copies instead of the whole message.
    /// `attachment`: the attachment right-clicked, whose items (Quick Look, Save, Copy) follow the reactions.
    func contextMenu(selection: String? = nil, attachment: Attachment? = nil) -> NSMenu {
        let menu = MessageMenu()
        menu.keepsSystemItems = selection?.isEmpty == false   // selected text keeps Look Up, Translate, Services…
        guard let message = row?.message else { return menu }
        defer { menu.seal() }
        let strip = NSMenuItem()
        strip.view = ReactionStrip(emoji: quickReactions(ReactionStrip.count), react: { [weak self, weak menu] emoji in
            self?.react(emoji, to: message); menu?.cancelTracking()
        }, more: { [weak self, weak menu] in
            menu?.afterClose = { self?.showEmojiPicker() }
            menu?.cancelTracking()
        })
        menu.addItem(strip)
        menu.addItem(.separator())
        if let attachment, let items = actions.files?.menuItems(attachment), !items.isEmpty {
            items.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        if message.delivery == .sent { menu.addItem(ClosureMenuItem("Reply") { [actions] in actions.quote(message) }) }
        menu.addItem(ClosureMenuItem("Reply in Thread") { [actions] in actions.openThread(message) })
        if message.delivery == .sent, !message.isSystem, let forward = actions.forward { menu.addItem(ClosureMenuItem("Forward…") { forward(message) }) }
        menu.addItem(ClosureMenuItem("Copy") { [weak self, actions] in
            if let selection, !selection.isEmpty { Self.pasteboard.clearContents(); Self.pasteboard.setString(selection, forType: .string) }
            else if let rich = self?.textView.attributedString(), rich.length > 0 { Self.copy(rich) }
            else { actions.copy(message) }
        })
        if message.delivery == .sent, let link = ChatLink.url(message: message.id) {
            menu.addItem(ClosureMenuItem("Copy Message Link") { ChatLink.copy(link) })
        }
        if message.delivery == .sent, let star = actions.star {
            menu.addItem(ClosureMenuItem(message.starred ? "Unstar" : "Star") { star(!message.starred, message) })
        }
        if message.delivery == .sent, !message.isSystem, let pin = actions.pin {
            menu.addItem(ClosureMenuItem(message.pinned ? "Unpin from Board" : "Pin to Board") { pin(!message.pinned, message) })
        }
        if message.delivery == .sent, let markUnread = actions.markUnread {
            menu.addItem(ClosureMenuItem("Mark as Unread") { markUnread(message) })
        }
        if message.delivery == .sent, message.sender.id != meID, let report = actions.report {
            menu.addItem(ClosureMenuItem("Report…") { report(message) })
        }
        if own && message.delivery == .sent {
            menu.addItem(.separator())
            let readers = actions.readers(message)
            if !readers.isEmpty {
                let seen = NSMenuItem(title: "Seen by " + ListFormatter.localizedString(byJoining: readers), action: nil, keyEquivalent: "")
                seen.isEnabled = false
                menu.addItem(seen)
            }
            menu.addItem(ClosureMenuItem("Edit") { [actions] in actions.edit(message) })
            menu.addItem(ClosureMenuItem("Delete…") { [actions] in actions.delete(message) })   // asks first: it goes for everyone
        }
        return menu
    }

    private func quickReactions(_ count: Int) -> [String] { actions.emojiUsage?.top(count) ?? Array(EmojiUsage.defaults.prefix(count)) }
    private func react(_ emoji: String, to message: Message) {
        actions.emojiUsage?.record(emoji)
        actions.react(emoji, message)
    }
    /// The full emoji picker, for reacting to this row's message; it closes once one is picked.
    func emojiPopover() -> NSPopover? {
        guard hasActions, let message = row?.message else { return nil }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: EmojiPicker(
            frequent: quickReactions(EmojiPicker.columns),
            pick: { [weak self, weak popover] emoji in self?.react(emoji, to: message); popover?.close() },
            close: { [weak popover] in popover?.close() },
            custom: actions.customEmoji,
            pickCustom: { [actions, weak popover] emoji in actions.reactCustom(emoji, message); popover?.close() },
            loadImage: actions.loadAttachment))
        return popover
    }
    @objc func showEmojiPicker() {
        guard window != nil, let popover = emojiPopover(), let layout = rowLayout else { return }
        emojiPicker?.close()
        emojiPicker = popover
        popover.show(relativeTo: style == .plain ? layout.text ?? layout.bubble : layout.bubble, of: self, preferredEdge: .maxY)
    }

    /// A stable colour per person (a fixed string hash; `hashValue` changes between launches), as Telegram colours names.
    static func color(for key: String) -> NSColor {
        let palette: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink]
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

/// The bubble: a shape layer with a rounded body and, on a run's last bubble, a tail curving out of the bottom corner
/// on the sender's side (the shape of Telegram's bubble images, drawn as a path).
final class BubbleView: NSView {
    var own = false { didSet { if own != oldValue { refresh() } } }
    var fill = NSColor.controlAccentColor { didSet { if fill != oldValue { refresh() } } }
    var tail = false { didSet { if tail != oldValue { refresh() } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks reach the row (its menu) and the text
    // The shape is set directly: AppKit does not call updateLayer() for these views inside table rows.
    override func layout() { super.layout(); refresh() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        guard let layer = layer as? CAShapeLayer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.path = Self.path(size: bounds.size, tail: tail, mirrored: own)
        effectiveAppearance.performAsCurrentDrawingAppearance {   // resolve dynamic colours for light/dark
            layer.fillColor = fill.cgColor   // BubblePalette's
            // Increase Contrast: an outline, so a pale incoming bubble doesn't melt into a light background.
            let outlined = !own && fill != .clear && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            layer.strokeColor = outlined ? NSColor.separatorColor.cgColor : nil
            layer.lineWidth = outlined ? 1 : 0
        }
        CATransaction.commit()
    }
    /// In layer coordinates (origin bottom-left). The body leaves `tailWidth` free on the left; `mirrored` puts it on the right.
    static func path(size: CGSize, tail: Bool, mirrored: Bool) -> CGPath {
        let t = RowLayout.tailWidth, w = size.width, h = size.height
        let r = min(RowLayout.cornerRadius, (w - t) / 2, h / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: t + r, y: h))
        path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w, y: 0), radius: r)
        path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: t, y: 0), radius: r)
        if tail {
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addCurve(to: CGPoint(x: t, y: min(12, h - r)), control1: CGPoint(x: t * 0.75, y: 1.5), control2: CGPoint(x: t, y: 5))
        } else {
            path.addArc(tangent1End: CGPoint(x: t, y: 0), tangent2End: CGPoint(x: t, y: h), radius: r)
        }
        path.addArc(tangent1End: CGPoint(x: t, y: h), tangent2End: CGPoint(x: w, y: h), radius: r)
        path.closeSubpath()
        guard mirrored else { return path }
        var flip = CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &flip) ?? path
    }
}

/// The avatar never takes clicks itself: the row offers the sender's menu (`personMenu`).
final class AvatarHostView: NSHostingView<Avatar> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// The header of a sender's menu.
struct PersonCard: View {
    let person: Person
    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: person.name, size: 36, url: person.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.headline)
                if let email = person.email { Text(email).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.horizontal, 14).padding(.vertical, 6).frame(minWidth: 220, alignment: .leading)
    }
}

/// A quote's tinted block with its leading bar.
final class QuoteView: NSView {
    var bar = NSColor.systemBlue { didSet { needsDisplay = true } }
    var fill = NSColor.clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        fill.setFill(); shape.fill()
        shape.addClip()
        bar.setFill(); NSRect(x: 0, y: 0, width: RowLayout.quoteBar, height: bounds.height).fill()
    }
    /// Set when the quoted message is known: a click goes to it.
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { onClick == nil ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

/// Text drawn into its bounds with `RowLayout.drawing`, the options it was measured with. With a background it is a
/// pill (text inset by `inset`); with `onClick` it is a button.
final class TextLabel: NSView {
    var text = NSAttributedString() { didSet { needsDisplay = true; setAccessibilityLabel(text.string) } }
    var background: NSColor? { didSet { needsDisplay = true } }
    var inset = NSSize.zero
    var onClick: (() -> Void)? {
        didSet { setAccessibilityElement(onClick != nil); setAccessibilityRole(onClick == nil ? .staticText : .button); window?.invalidateCursorRects(for: self) }
    }
    /// Called when the pointer enters the label.
    var onHover: (() -> Void)? {
        didSet {
            guard oldValue == nil, onHover != nil else { return }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }
    var onExit: (() -> Void)?   // when the pointer leaves a label with `onHover`
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { onExit?() }   // not passed on: the row tracks its own hover
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let background {
            background.setFill()
            let radius = min(bounds.height / 2, 11)   // a capsule on one line; a wrapped service line keeps soft corners
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        text.draw(with: bounds.insetBy(dx: inset.width, dy: inset.height), options: RowLayout.drawing)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { onClick == nil ? nil : super.hitTest(point) }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

extension MessageRowView {
    /// A source that is a Google Chat message opens in Parley, as a Chat link in a message does; anything else in the browser.
    static func open(source url: URL, chatLink: (ChatLink, URL) -> Void, browser: (URL) -> Void) {
        if let link = ChatLink(url) { chatLink(link, url) } else { browser(url) }
    }
    /// The sources of a Gemini answer, one item each with its kind's icon; choosing one opens it in the browser.
    static func sourcesMenu(_ sources: [Source], open: @escaping (URL) -> Void) -> NSMenu {
        let menu = NSMenu()
        for source in sources {
            let item = ClosureMenuItem(source.title) { open(source.url) }
            item.image = NSImage(systemSymbolName: RowLayout.symbol(source.kind), accessibilityDescription: nil)
            if #available(macOS 27, *) { item.preferredImageVisibility = .visible }   // menus hide item images unless asked
            item.toolTip = source.url.host()
            item.subtitle = source.detail   // a line from it, as Google Chat's source chips show
            menu.addItem(item)
        }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    let handler: () -> Void   // also VoiceOver's action of the same name (see MessageRowView.accessibilityCustomActions)
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// Our message menus take no items from the system (context-menu plug-ins, Writing Tools, anything appended as the
/// menu opens), so the menu is the same whether it opens on the text or on the bubble.
final class MessageMenu: NSMenu, NSMenuDelegate {
    private var own: Set<ObjectIdentifier> = []
    /// Opened on selected text: the system's items for it (Look Up, Translate, Search With Google, Share, Services,
    /// Speech) join ours, as in Messages.
    var keepsSystemItems = false { didSet { allowsContextMenuPlugIns = keepsSystemItems } }
    /// Runs once the menu has closed: a popover can't open while the menu still tracks.
    var afterClose: (@MainActor () -> Void)?
    init() {
        super.init(title: "")
        allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { automaticallyInsertsWritingToolsItems = false }
        delegate = self
    }
    required init(coder: NSCoder) { fatalError() }
    /// The items so far are ours; others are dropped when the menu opens.
    func seal() { own = Set(items.map(ObjectIdentifier.init)) }
    func menuWillOpen(_ menu: NSMenu) {
        guard !keepsSystemItems else { return }
        for item in items where !own.contains(ObjectIdentifier(item)) { removeItem(item) }
    }
    func menuDidClose(_ menu: NSMenu) {
        guard let afterClose else { return }
        self.afterClose = nil
        Task { @MainActor in afterClose() }
    }
}

/// The quick-reaction row at the top of a message's context menu, then a button for the full picker.
final class ReactionStrip: NSView {
    static let count = 6
    let emoji: [String]
    private(set) var buttons: [NSButton] = []
    let moreButton = NSButton(title: "", target: nil, action: nil)
    private let react: (String) -> Void
    private let more: () -> Void
    init(emoji: [String], react: @escaping (String) -> Void, more: @escaping () -> Void) {
        self.emoji = emoji; self.react = react; self.more = more
        super.init(frame: NSRect(x: 0, y: 0, width: 14 + CGFloat(emoji.count + 1) * 36, height: 38))
        for (index, emoji) in emoji.enumerated() {
            let button = NSButton(title: emoji, target: self, action: #selector(tapped(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 22)
            button.tag = index
            button.frame = NSRect(x: 7 + CGFloat(index) * 36, y: 3, width: 36, height: 32)
            button.setAccessibilityLabel("React with \(emoji)")
            buttons.append(button)
            addSubview(button)
        }
        moreButton.isBordered = false
        // The color is part of the image: on macOS 15 a menu item's view drew the tinted template symbol blank.
        let symbol = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "More reactions")?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))
        if let symbol { moreButton.image = symbol; moreButton.imagePosition = .imageOnly } else { moreButton.title = "+"; moreButton.font = .systemFont(ofSize: 22) }
        moreButton.target = self; moreButton.action = #selector(showMore)
        moreButton.frame = NSRect(x: 7 + CGFloat(emoji.count) * 36, y: 3, width: 36, height: 32)
        moreButton.setAccessibilityLabel("More reactions")
        moreButton.toolTip = "More Reactions"
        addSubview(moreButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped(_ sender: NSButton) { react(emoji[sender.tag]) }
    @objc private func showMore() { more() }
}

/// The bubble's text: right-click opens the message menu (as on the rest of the bubble), not the text menu.
final class MessageTextView: NSTextView {
    /// Resizing a text view scrolls its insertion point into view; in the timeline that would scroll the whole table.
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
    var messageMenu: ((String?) -> NSMenu?)?
    var mentionMenu: ((PersonID, _ name: String) -> NSMenu?)?   // a click on a mention: that person's card
    var openChatLink: ((ChatLink, URL) async -> Bool)?          // Google Chat links open in Parley, not the browser
    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = link as? URL ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, let chat = ChatLink(url), openChatLink != nil else { return super.clicked(onLink: link, at: charIndex) }
        open(chat, url, at: lastClick)
    }
    /// Opens a Chat link in Parley; one this account can't open gets web's card where it was clicked, not the browser.
    private func open(_ chat: ChatLink, _ url: URL, at point: NSPoint) {
        guard let openChatLink, let window else { return }
        // Where it was clicked, in screen coordinates, taken now: by the time Parley knows, the row may be another's.
        let screen = window.convertToScreen(convert(NSRect(x: point.x, y: point.y - 8, width: 1, height: 16), to: nil))
        Task {
            guard await !openChatLink(chat, url) else { return }
            ChatLink.showRestricted(chat, above: screen, in: window)
        }
    }
    private var lastClick = NSPoint.zero
    /// A click on a mention pops its card up, on a chip opens its conversation; anywhere else selects text and follows
    /// links as usual.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastClick = point
        if let url = chip(at: point), let chat = ChatLink(url) { return open(chat, url, at: point) }
        guard let (id, name) = mention(at: point), let menu = mentionMenu?(id, name) else { return super.mouseDown(with: event) }
        menu.popUp(positioning: nil, at: point, in: self)
    }
    func chip(at point: NSPoint) -> URL? {
        characterIndex(at: point).flatMap { textStorage?.attribute(MessageTextStyle.chipKey, at: $0, effectiveRange: nil) as? URL }
    }
    /// The mention whose glyphs are under `point` (view coordinates): its user id and text without the "@".
    func mention(at point: NSPoint) -> (PersonID, String)? {
        guard let textStorage, let index = characterIndex(at: point) else { return nil }
        var range = NSRange()
        guard let id = textStorage.attribute(MessageTextStyle.mentionKey, at: index, effectiveRange: &range) as? String else { return nil }
        let text = (textStorage.string as NSString).substring(with: range)
        return (id, text.hasPrefix("@") ? String(text.dropFirst()) : text)
    }
    /// The character whose glyph is under `point` (view coordinates); nil between and after glyphs.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    // An emoji in the text shows the reaction pills' hover card: the emoji large and its :name:, as Google Chat web does.
    var loadAttachment: (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }   // custom emoji pictures
    private var hovered: NSRange?
    /// The emoji at `index`, standard or custom: its card and the characters it covers. Nil for any other character.
    func emojiCard(at index: Int) -> (content: ReactionCardView, range: NSRange)? {
        guard let textStorage, index >= 0, index < textStorage.length else { return nil }
        if let custom = textStorage.attribute(MessageTextStyle.emojiKey, at: index, effectiveRange: nil) as? CustomEmoji {
            return (ReactionCardView(reaction: Reaction(emoji: custom.text, people: [], custom: custom), names: "", load: loadAttachment),
                    NSRange(location: index, length: 1))
        }
        let string = textStorage.string as NSString, range = string.rangeOfComposedCharacterSequence(at: index)
        let emoji = string.substring(with: range)
        guard let character = emoji.first, emoji.count == 1, character.isEmojiGlyph else { return nil }
        let name = (character.unicodeScalars.first?.properties.name ?? "").lowercased().replacingOccurrences(of: " ", with: "-")
        return (ReactionCardView(reaction: Reaction(emoji: emoji, people: []), names: ":\(name):", load: loadAttachment), range)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let card = characterIndex(at: convert(event.locationInWindow, from: nil)).flatMap(emojiCard)
        guard card?.range != hovered else { return }
        hovered = card?.range
        guard let card, let layoutManager, let textContainer else { return ReactionCard.shared.hide(self) }
        let glyphs = layoutManager.glyphRange(forCharacterRange: card.range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        ReactionCard.shared.hover(self, card.content, at: rect)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = nil; ReactionCard.shared.hide(self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let range = selectedRange()
        let selection = range.length > 0 ? (string as NSString).substring(with: range) : nil
        guard let menu = messageMenu?(selection) else { return super.menu(for: event) }
        // Selected text: the text's own items (Look Up, Translate, Search With Google, Share, Speech) follow ours.
        if selection != nil, let text = super.menu(for: event) {
            let wanted = text.items.filter { $0.isEnabled || $0.hasSubmenu || $0.isSeparatorItem }
            if !wanted.isEmpty { menu.addItem(.separator()) }
            for item in wanted { text.removeItem(item); menu.addItem(item) }
        }
        return menu
    }
    /// Pops the message menu up for the row, not for the text, so the system adds no text items to it; with text
    /// selected, for the text, so the system adds its items for the selection (Services).
    override func rightMouseDown(with event: NSEvent) {
        guard messageMenu != nil, let row = superview, let menu = menu(for: event) else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: selectedRange().length > 0 ? self : row)
    }
}

/// A Gemini answer's steps, as Google Chat lists them under "Show thinking": each step's title, then what it did.
struct ThinkingView: View {
    let steps: [ThinkingStep]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).font(.headline)
                        Text(step.text).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16).frame(width: 380, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }
}

/// What a reaction pill's hover card shows, as Google Chat web does: the emoji large, a custom emoji's `:name:`, who reacted.
struct ReactionCardView: View {
    let reaction: Reaction
    var names: String
    let load: (Attachment, Bool) async throws -> Data
    var body: some View {
        VStack(spacing: 4) {
            if let custom = reaction.custom {
                CustomEmojiImage(emoji: custom, size: 40, load: load)
                Text(custom.text).font(.caption.weight(.semibold))
            } else {
                Text(reaction.emoji).font(.system(size: 36))
            }
            if !names.isEmpty {
                Text(names).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(minWidth: 80, maxWidth: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}

/// A reaction pill's hover card: shown once the pointer rests on the pill, updated in place when the names arrive, gone on
/// exit, click or scroll. A borderless child panel that ignores the mouse rather than a popover: it never takes focus,
/// activation or the pill's clicks, and has no arrow or animation for a passing glance.
@MainActor final class ReactionCard {
    static let shared = ReactionCard()
    var delay: Duration = .milliseconds(400)
    private(set) var content: ReactionCardView?
    private(set) var panel: NSPanel?
    private weak var anchor: NSView?
    private var anchorRect: NSRect?   // in the anchor's coordinates: an emoji inside a text view; nil: the whole anchor
    private var pending: Task<Void, Never>?
    private var scrolling: NSObjectProtocol?

    var isShown: Bool { panel?.parent != nil }
    func hover(_ pill: NSView, _ content: ReactionCardView, at rect: NSRect? = nil) {
        hide()
        anchor = pill; anchorRect = rect; self.content = content
        pending = Task { [weak self] in
            try? await Task.sleep(for: self?.delay ?? .zero)
            guard !Task.isCancelled else { return }
            self?.show()
        }
    }
    /// New content for `pill`'s card, shown or still waiting; another pill's is ignored.
    func update(_ pill: NSView, _ content: ReactionCardView) {
        guard anchor === pill else { return }
        self.content = content
        if isShown { show() }
    }
    /// Hides the card; with a pill, only that pill's.
    func hide(_ pill: NSView? = nil) {
        if let pill, anchor !== pill { return }
        pending?.cancel(); pending = nil
        if let scrolling { NotificationCenter.default.removeObserver(scrolling) }
        scrolling = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        anchor = nil
    }
    private func show() {
        guard let anchor, let content, let window = anchor.window else { return hide() }
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: content)
            self.panel = panel
            return panel
        }()
        guard let host = panel.contentView as? NSHostingView<ReactionCardView> else { return }
        host.rootView = content
        let size = host.fittingSize
        let pill = window.convertToScreen(anchor.convert(anchorRect ?? anchor.bounds, to: nil))
        panel.setFrame(NSRect(x: pill.midX - size.width / 2, y: pill.maxY + 6, width: size.width, height: size.height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if scrolling == nil, let clip = anchor.enclosingScrollView?.contentView {
            scrolling = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }
}

/// Message text's own drawing: text backgrounds (a chip's pill, inline code) with rounded corners, as Google Chat draws
/// them, and a quote's bar or a code block's background over every line of the block.
final class MessageLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let all = NSRange(location: 0, length: storage.length), shown = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for key in [MessageTextStyle.codeFillKey, MessageTextStyle.quoteBarKey] {
            storage.enumerateAttribute(key, in: shown) { value, run, _ in
                guard let color = value as? NSColor else { return }
                var block = NSRange()   // the whole block, even when only part of it is being drawn
                _ = storage.attribute(key, at: run.location, longestEffectiveRange: &block, in: all)
                var lines = NSRect.null
                enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: block, actualCharacterRange: nil)) { fragment, _, _, _, _ in
                    lines = lines.union(fragment)
                }
                guard !lines.isNull else { return }
                lines = lines.offsetBy(dx: origin.x, dy: origin.y)
                color.setFill()
                if key == MessageTextStyle.codeFillKey { NSBezierPath(roundedRect: lines, xRadius: 6, yRadius: 6).fill() }
                else { NSBezierPath(roundedRect: NSRect(x: lines.minX, y: lines.minY, width: 3, height: lines.height), xRadius: 1.5, yRadius: 1.5).fill() }
            }
        }
    }
    override func fillBackgroundRectArray(_ rects: UnsafePointer<NSRect>, count: Int, forCharacterRange range: NSRange, color: NSColor) {
        let path = NSBezierPath()
        for i in 0..<count { path.append(NSBezierPath(roundedRect: rects[i], xRadius: 5, yRadius: 5)) }
        color.setFill()
        path.fill()
    }
}
