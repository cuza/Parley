import AppKit
import ParleyDomain
import SwiftUI

/// One message in the timeline, as AppKit views placed by frame from its `RowLayout`:
/// no Auto Layout, and the only hosted SwiftUI (avatar, attachments) gets a fixed frame it never sizes itself.
/// Reusable: `configure` again with another row. When the row's width changes, `layout()` recomputes the layout.
/// Its menus (the message's, a person's, the emoji picker) are in `MessageRowView+Menus.swift`.
final class MessageRowView: NSTableRowView {
    private(set) var row: TimelineRow?
    private(set) var rowLayout: RowLayout?
    private var timeOnly = false
    /// Where a timeline's row view gets its layout when its width changes: the table's cache. Without one, it measures.
    var layoutFor: (@MainActor (TimelineRow) -> RowLayout?)?
    private(set) var style = TimelineStyle.bubbles
    private(set) var own = false
    private(set) var kind = ConversationKind.direct
    private(set) var actions = MessageRowActions()
    private(set) var meID: PersonID = ""
    private var highlighted = false
    private var pictures = false  // the time is on a pill over the last picture

    let dateLabel = TextLabel()
    let avatarView = AvatarHostView(rootView: Avatar(name: "", size: RowLayout.avatarSize))
    let bubbleView = BubbleView()
    let nameLabel = TextLabel()
    let viaLabel = TextLabel()  // the app that posted for the sender, after the name
    let quoteView = QuoteView()
    let quoteSenderLabel = TextLabel()
    let quoteTextLabel = TextLabel()
    /// Revealed at the right edge while the row is swiped toward reply (`setSwipe`): the quote arrow, or the thread icon
    /// once the swipe reaches the thread stage.
    let replyArrow = NSImageView(image: MessageRowView.quoteIcon)
    let textView: MessageTextView = {  // TextKit 1, as `MessageTextStyle.measure`; rounded backgrounds, as chips need
        let view = MessageTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(MessageLayoutManager())
        return view
    }()
    private(set) var attachmentViews: [AttachmentHostView] = []
    private(set) var reactionPills: [TextLabel] = []
    var emojiTask: Task<Void, Never>?
    lazy var emojiAnimation = EmojiAnimation(self) { [weak self] in self?.redrawEmoji() }  // while the row shows an animated custom emoji
    let repliesLink = TextLabel()
    let sourcesLink = TextLabel()  // a Gemini answer's "N Sources": a click lists them
    let translationLink = TextLabel()  // a translated message's "View original (…)" / "Show translation"
    let thinkingLink = TextLabel()  // a Gemini answer's "Show thinking": a click shows its steps
    let timeLabel = TextLabel()
    let retryLink = TextLabel()
    let serviceLabel = TextLabel()  // a system event's pill, instead of the bubble
    let seenLabel = TextLabel()
    /// Behind the time on a picture: the picture blurred under the pill (Telegram's), made when a row first needs one.
    private var pillBlur: NSVisualEffectView?
    /// A jump to this message: the whole row flashes, as Telegram's does, over the picture too.
    let flash = CALayer()
    /// Selected from the keyboard: a soft accent wash behind the row, as a selected message in Mail.
    let selectionHighlight = CALayer()
    override var isSelected: Bool {
        didSet {
            CATransaction.withoutAnimation {
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    selectionHighlight.backgroundColor =
                        isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
                }
            }
        }
    }
    /// Beside the last reaction pill while the pointer is over the row: opens the emoji picker (Slack's "add reaction").
    /// Made on the first hover: most rows are never hovered, and a button was most of what a new row cost.
    private(set) lazy var addReactionButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Add Reaction") ?? NSImage(),
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
    var hovering = false { didSet { if hovering != oldValue { needsLayout = true } } }
    var hoverArea: NSTrackingArea?
    var emojiPicker: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
        avatarView.sizingOptions = []
        replyArrow.contentTintColor = .controlAccentColor
        replyArrow.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        replyArrow.alphaValue = 0
        addSubview(replyArrow)
        textView.isEditable = false
        textView.isSelectable = true
        // macOS otherwise draws a Siri / Writing Tools badge on the bubble; message text is read-only.
        if #available(macOS 15.2, *) { textView.writingToolsBehavior = .none }
        textView.messageMenu = { [weak self] selection in
            self?.hasActions == true ? self?.contextMenu(selection: selection) : nil
        }
        textView.mentionMenu = { [weak self] id, name in self?.mentionMenu(id, name: name) }
        textView.openChatLink = { [weak self] link, url in await self?.actions.openChatLink(link, url) ?? true }
        textView.loadAttachment = { [weak self] in
            try await (self?.actions.loadAttachment ?? { _, _ in throw CancellationError() })($0, $1)
        }
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        serviceLabel.inset = RowLayout.serviceInset
        viaLabel.background = .labelColor.withAlphaComponent(0.08)
        viaLabel.inset = RowLayout.viaInset
        wantsLayer = true
        flash.backgroundColor = NSColor.controlAccentColor.cgColor  // set again as it flashes, for the current accent
        flash.opacity = 0
        flash.zPosition = 10
        layer?.addSublayer(flash)
        selectionHighlight.zPosition = -1
        layer?.addSublayer(selectionHighlight)
        let views: [NSView] = [
            dateLabel, avatarView, bubbleView, quoteView, quoteSenderLabel, quoteTextLabel, nameLabel, viaLabel,
            textView,
            repliesLink, sourcesLink, translationLink, thinkingLink, timeLabel, retryLink, serviceLabel, seenLabel,
        ]
        for view in views {
            view.autoresizingMask = []
            addSubview(view)
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The whole message as rich text (⌘C on a selected row), or plain when it has no text view content.
    func copyMessage() {
        let rich = textView.attributedString()
        if rich.length > 0 { Self.copy(rich) } else if let message = row?.message { actions.copy(message) }
    }
    /// Where Copy writes; tests use their own.
    static var pasteboard = NSPasteboard.general
    /// The message as shown, as rich text (links, bold, lists) for Mail and Notes and plain text for the rest. The bubble's
    /// colours stay behind: pasted, they'd be the bubble's, not the document's.
    static func copy(_ rich: NSAttributedString) {
        let clean = NSMutableAttributedString(attributedString: rich)
        let all = NSRange(location: 0, length: clean.length)
        clean.removeAttribute(.foregroundColor, range: all)
        clean.removeAttribute(.backgroundColor, range: all)
        pasteboard.clearContents()
        pasteboard.writeObjects([clean])
    }
    /// Shows `row`. Pass `layout` when it was already computed for this row at the row view's width (the table's
    /// height cache); otherwise it is computed at the next `layout()`.
    func configure(
        _ row: TimelineRow, own: Bool, kind: ConversationKind, meID: PersonID, layout: RowLayout? = nil,
        highlighted: Bool = false, style: TimelineStyle = .bubbles, actions: MessageRowActions
    ) {
        let own = own && style == .bubbles  // plain shows everyone like an incoming message
        let pictures = RowLayout.timeOnPicture(row.message, style: style) && !row.draft  // the time is on a pill over the last picture
        self.pictures = pictures
        let flashes = highlighted && !(self.highlighted && self.row?.id == row.id)  // newly jumped to
        if self.row?.id != row.id { flash.removeAnimation(forKey: "flash") }
        let lone = RowLayout.mediaOnly(row.message, style: style)  // no bubble: what sits under the pictures is not on mine
        if style != self.style {
            rowLayout = layout
            self.style = style
        }
        if row != self.row || own != self.own || kind != self.kind {
            rowLayout = layout
        } else if let layout {
            rowLayout = layout
        }
        self.row = row
        self.own = own
        self.kind = kind
        self.actions = actions
        self.meID = meID
        // VoiceOver reads the row as one line; its actions are the menu's (built only when VoiceOver asks). The row stays a
        // container, so the text inside (its links, a selection) can still be reached.
        setAccessibilityLabel(Self.spoken(row, own: own))
        if flashes { flashRow() }
        self.highlighted = highlighted
        configureLabels(row, lone: lone)
        configureAttachments(row)
        configureReactions(row.message, lone: lone)
        loadCustomEmoji(row.message)
        configureLinks(row, lone: lone)
        setAccessibilityIdentifier(row.message.id.rawValue)
        needsLayout = true
    }

    override func layout() {
        placeReplyArrow()
        super.layout()
        guard let row else { return }
        if rowLayout?.width != bounds.width {
            rowLayout =
                layoutFor.map { $0(row) ?? rowLayout }
                ?? RowLayout.make(row, width: bounds.width, own: own, kind: kind, style: style)
        }
        guard let layout = rowLayout else { return }
        if layout.timeOnly != timeOnly, let message = self.row?.message {  // a picture too narrow for the pill's extras
            timeOnly = layout.timeOnly
            timeLabel.text = RowLayout.timeText(message, color: .white, timeOnly: timeOnly)
        }
        place(dateLabel, layout.dateHeader)
        place(avatarView, layout.avatar)
        // The bubble view also holds the tail, on the sender's side; the shape decides whether to draw it.
        place(
            bubbleView,
            CGRect(
                x: layout.bubble.minX - (own ? 0 : RowLayout.tailWidth), y: layout.bubble.minY,
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
        for (view, corners) in zip(attachmentViews, layout.attachmentCorners) where view.rootView.corners != corners {
            view.rootView.corners = corners
        }
        for (view, frame) in zip(reactionPills, layout.reactions) { place(view, frame) }
        place(repliesLink, layout.replies)
        place(sourcesLink, layout.sources)
        place(translationLink, layout.translation)
        place(thinkingLink, layout.thinking)
        place(timeLabel, layout.service == nil ? layout.time : nil)
        if pictures && layout.service == nil {
            placePillBlur(layout.time)
        } else if let pillBlur {
            place(pillBlur, nil)
        }
        CATransaction.withoutAnimation {
            flash.frame = bounds
            selectionHighlight.frame = bounds
        }
        place(retryLink, layout.retry)
        place(seenLabel, layout.seen)
        if hovering, let frame = addReactionFrame(layout) {
            place(addReactionButton, frame)
        } else if madeAddReaction {
            place(addReactionButton, nil)
        }
    }
    private func placePillBlur(_ frame: CGRect) {
        let blur =
            pillBlur
            ?? {
                let view = NSVisualEffectView()
                view.blendingMode = .withinWindow
                view.state = .active
                view.material = .hudWindow
                view.wantsLayer = true
                view.layer?.masksToBounds = true
                view.autoresizingMask = []
                pillBlur = view
                return view
            }()
        // Above the pictures (added under the time as they come), right under the time.
        if let index = subviews.firstIndex(of: timeLabel), index == 0 || subviews[index - 1] !== blur {
            addSubview(blur, positioned: .below, relativeTo: timeLabel)
        }
        place(blur, frame)
        blur.layer?.cornerRadius = frame.height / 2
    }
    /// Telegram's jump flash: the row tints to half its blue and back.
    private func flashRow() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            flash.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.5, 0.5, 0]
        fade.keyTimes = [0, 0.15, 0.55, 1]
        fade.duration = 1.5
        flash.add(fade, forKey: "flash")
    }
    private func place(_ view: NSView, _ frame: CGRect?) {
        view.isHidden = frame == nil
        if let frame, view.frame != frame { view.frame = frame }
    }

    /// A stable colour per person (a fixed string hash; `hashValue` changes between launches), as Telegram colours names.
    static func color(for key: String) -> NSColor {
        let palette: [NSColor] = [
            .systemRed, .systemOrange, .systemGreen, .systemTeal, .systemBlue, .systemIndigo, .systemPurple,
            .systemPink,
        ]
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

// MARK: Configuring the row's parts, in `configure`'s order

extension MessageRowView {
    /// The date header, avatar, bubble, sender line, quote, text, time, retry, service line and "Seen".
    fileprivate func configureLabels(_ row: TimelineRow, lone: Bool) {
        let message = row.message
        let ink = BubblePalette.ownInk
        let accent = BubblePalette.ownAccent
        let secondary: NSColor = own && !lone ? accent.withAlphaComponent(0.75) : .secondaryLabelColor
        dateLabel.text = RowLayout.dateText(message, color: BubblePalette.serviceText)
        dateLabel.background = BubblePalette.servicePill
        dateLabel.inset = RowLayout.serviceInset
        // Only when it changes: a SwiftUI update (and its image task) on every row reused while scrolling adds up.
        if avatarView.rootView.name != message.sender.name || avatarView.rootView.url != message.sender.avatarURL {
            avatarView.rootView = Avatar(
                name: message.sender.name, size: RowLayout.avatarSize, url: message.sender.avatarURL)
        }
        bubbleView.fill = lone ? .clear : own ? BubblePalette.own : BubblePalette.incoming
        bubbleView.own = own
        nameLabel.text = RowLayout.nameText(message.sender.name, color: Self.color(for: message.sender.id.rawValue))
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
            quoteTextLabel.text = RowLayout.quoteBodyText(
                quote, color: own ? ink.withAlphaComponent(0.85) : .secondaryLabelColor)
        }
        NativeMessageText.show(
            message.text, formatting: message.formatting, own: own, jumbo: message.jumboEmoji, in: textView)
        // Links on my bubble take its accent, as Telegram draws them; elsewhere the system link colour.
        textView.linkTextAttributes = [
            .foregroundColor: own ? accent : .linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand,
        ]
        let bare = message.jumboEmoji != nil  // large emoji: the time sits on a pill, as on a service line
        timeOnly = false
        timeLabel.text = RowLayout.timeText(
            message, color: pictures ? .white : bare ? BubblePalette.serviceText : secondary)
        timeLabel.background = pictures ? BubblePalette.mediaPill : bare ? BubblePalette.timePill : nil
        timeLabel.inset = pictures ? RowLayout.mediaPillInset : bare ? RowLayout.jumboTimeInset : .zero
        retryLink.text = RowLayout.retryText()
        retryLink.onClick = { [weak self] in self?.actions.retry(message) }
        serviceLabel.text =
            message.isSystem
            ? RowLayout.serviceText(message.text, color: BubblePalette.serviceText) : NSAttributedString()
        serviceLabel.background =
            Wallpaper.current(dark: effectiveAppearance.isDark) == .none
            ? .labelColor.withAlphaComponent(0.06) : BubblePalette.servicePill
        serviceLabel.toolTip = message.isSystem ? message.text : nil
        seenLabel.text = RowLayout.seenText(row.seenBy, kind: kind)
        timeLabel.toolTip = message.createdAt.formatted(date: .complete, time: .standard)  // on the time only: a row-wide one gets in the way
    }
    /// One hosted `AttachmentView` per attachment, reused from the last row this view showed.
    fileprivate func configureAttachments(_ row: TimelineRow) {
        let message = row.message
        while attachmentViews.count > message.attachments.count { attachmentViews.removeLast().removeFromSuperview() }
        for (index, attachment) in message.attachments.enumerated() {
            let content = AttachmentView(
                attachment: attachment, load: actions.loadAttachment, own: own, transcriptOpen: row.transcriptOpen,
                toggleTranscript: { [weak self] in self?.actions.toggleTranscript(message) },
                dismissCard: { [weak self] in self?.actions.dismissCard(message) },
                clickCard: { [weak self] card, action, inputs in
                    await self?.actions.clickCard(message, card, action, inputs)
                })
            if index < attachmentViews.count {
                attachmentViews[index].rootView = content
            } else {
                let host = AttachmentHostView(rootView: content)
                host.sizingOptions = []
                host.autoresizingMask = []
                addSubview(host, positioned: .below, relativeTo: timeLabel)
                attachmentViews.append(host)
            }
            attachmentViews[index].attachment = attachment
            attachmentViews[index].files = actions.files
        }
    }
    /// One pill per reaction: a click toggles mine, a hover shows who reacted.
    fileprivate func configureReactions(_ message: Message, lone: Bool) {
        let ink = BubblePalette.ownInk
        while reactionPills.count > message.reactions.count { reactionPills.removeLast().removeFromSuperview() }
        while reactionPills.count < message.reactions.count {
            let pill = TextLabel()
            pill.autoresizingMask = []
            addSubview(pill, positioned: .below, relativeTo: timeLabel)
            reactionPills.append(pill)
        }
        for (pill, reaction) in zip(reactionPills, message.reactions) {
            let mine = reaction.people.contains(meID)
            let onMine = own && !lone && !pictures  // under a picture's bubble, reactions sit outside it
            pill.text = RowLayout.pillText(reaction, color: onMine ? ink : .labelColor)
            pill.background =
                onMine
                ? ink.withAlphaComponent(mine ? 0.35 : 0.2)
                : mine ? .controlAccentColor.withAlphaComponent(0.18) : .labelColor.withAlphaComponent(0.07)
            pill.inset = RowLayout.pillInset
            pill.onClick = { [weak self, weak pill] in
                ReactionCard.shared.hide(pill)
                self?.actions.react(reaction.emoji, message)
            }
            pill.setAccessibilityLabel("\(reaction.emoji) \(reaction.people.count)")
            // Names are looked up when the pointer reaches the pill, so they are usually in before the card shows.
            pill.onHover = { [weak self, weak pill] in
                guard let self, let pill else { return }
                var card = ReactionCardView(
                    reaction: reaction, names: ChatStore.reactorsLine(names: [], count: reaction.people.count),
                    load: actions.loadAttachment)
                ReactionCard.shared.hover(pill, card)
                Task {
                    guard let line = await self.actions.reactors(reaction, message),
                        self.row?.message.id == message.id, self.row?.message.reactions.contains(reaction) == true
                    else { return }
                    card.names = line
                    ReactionCard.shared.update(pill, card)
                }
            }
            pill.onExit = { [weak pill] in ReactionCard.shared.hide(pill) }
        }
    }
    /// The lines that open something: replies (the thread), a Gemini answer's sources and thinking, a translation's toggle.
    fileprivate func configureLinks(_ row: TimelineRow, lone: Bool) {
        let message = row.message
        let ink = BubblePalette.ownInk
        repliesLink.text = RowLayout.repliesText(
            message.replyCount, draft: row.draft, color: own && !lone ? ink : .controlAccentColor)
        repliesLink.onClick = { [weak self] in self?.actions.openThread(message) }
        sourcesLink.text =
            message.sources.isEmpty
            ? NSAttributedString() : RowLayout.sourcesText(message.sources, color: own ? ink : .controlAccentColor)
        // Under the bubble: the accent colour.
        translationLink.text =
            message.translation.map { RowLayout.translationText($0, showingOriginal: row.transcriptOpen) }
            ?? NSAttributedString()
        translationLink.onClick =
            message.translation == nil ? nil : { [weak self] in self?.actions.toggleTranscript(message) }
        thinkingLink.text =
            message.thinking.isEmpty
            ? NSAttributedString() : RowLayout.thinkingText(color: own ? ink : .controlAccentColor)
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
                Self.open(
                    source: url,
                    chatLink: { link, url in
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
    }
}
