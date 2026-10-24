import AppKit
import ParleyDomain
import SwiftUI

extension MessageRowView {
    override func menu(for event: NSEvent) -> NSMenu? { hasActions ? contextMenu() : nil }
    /// A service line and a deleted message offer no actions, as on the web: nothing to quote, react to or forward.
    var hasActions: Bool { row.map { !$0.message.isSystem && !$0.message.tombstone } ?? false }
    /// A click or right-click on the sender's avatar or name offers to message them.
    override func mouseDown(with event: NSEvent) {
        if !popUpPersonMenu(event) { super.mouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !popUpPersonMenu(event) { super.rightMouseDown(with: event) }
    }
    private func popUpPersonMenu(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard [avatarView, nameLabel].contains(where: { !$0.isHidden && $0.frame.contains(point) }),
            let menu = personMenu()
        else { return false }
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
        let host = NSHostingView(
            rootView: PersonCard(person: person, details: actions.cardDetails.map { load in { await load(person) } }) {
                [weak card] size in
                card?.view?.frame.size = size  // the menu makes room for the title and local time
            })
        host.frame.size = host.fittingSize
        card.view = host
        menu.addItem(card)
        menu.addItem(.separator())
        if let showDetails = actions.showDetails {
            menu.addItem(ClosureMenuItem("Show Details") { showDetails(person) })
        }
        menu.addItem(ClosureMenuItem("Message \(person.name)") { message(person) })
        return menu
    }
    /// Right-click, as in Telegram and iMessage: a strip of quick reactions, then the message actions.
    /// `selection`: text selected in the bubble, which Copy then copies instead of the whole message.
    /// `attachment`: the attachment right-clicked, whose items (Quick Look, Save, Copy) follow the reactions.
    func contextMenu(selection: String? = nil, attachment: Attachment? = nil) -> NSMenu {
        let menu = MessageMenu()
        menu.keepsSystemItems = selection?.isEmpty == false  // selected text keeps Look Up, Translate, Services…
        guard let message = row?.message else { return menu }
        defer { menu.seal() }
        let strip = NSMenuItem()
        strip.view = ReactionStrip(
            emoji: quickReactions(ReactionStrip.count),
            react: { [weak self, weak menu] emoji in
                self?.react(emoji, to: message)
                menu?.cancelTracking()
            },
            more: { [weak self, weak menu] in
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
        if message.delivery == .sent, !message.isSystem, let forward = actions.forward {
            menu.addItem(ClosureMenuItem("Forward…") { forward(message) })
        }
        menu.addItem(
            ClosureMenuItem("Copy") { [weak self, actions] in
                if let selection, !selection.isEmpty {
                    Self.pasteboard.clearContents()
                    Self.pasteboard.setString(selection, forType: .string)
                } else if let rich = self?.textView.attributedString(), rich.length > 0 {
                    Self.copy(rich)
                } else {
                    actions.copy(message)
                }
            })
        if message.delivery == .sent, let link = ChatLink.url(message: message.id) {
            menu.addItem(ClosureMenuItem("Copy Message Link") { ChatLink.copy(link) })
            // With text selected, the system's own Share (for the text) is the one shown.
            if !menu.keepsSystemItems {
                menu.addItem(NSSharingServicePicker(items: Self.shareItems(message)).standardShareMenuItem)
            }
        }
        if message.delivery == .sent, let star = actions.star {
            menu.addItem(ClosureMenuItem(message.starred ? "Unstar" : "Star") { star(!message.starred, message) })
        }
        if message.delivery == .sent, !message.isSystem, let pin = actions.pin {
            menu.addItem(
                ClosureMenuItem(message.pinned ? "Unpin from Board" : "Pin to Board") { pin(!message.pinned, message) })
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
                let seen = NSMenuItem(
                    title: "Seen by " + ListFormatter.localizedString(byJoining: readers), action: nil,
                    keyEquivalent: "")
                seen.isEnabled = false
                menu.addItem(seen)
            }
            menu.addItem(ClosureMenuItem("Edit") { [actions] in actions.edit(message) })
            menu.addItem(ClosureMenuItem("Delete…") { [actions] in actions.delete(message) })  // asks first: it goes for everyone
        }
        return menu
    }

    /// What Share… hands to the share sheet for a message: its Google Chat link, as Copy Message Link copies it.
    static func shareItems(_ message: Message) -> [Any] { ChatLink.url(message: message.id).map { [$0] } ?? [] }
    private func quickReactions(_ count: Int) -> [String] {
        actions.emojiUsage?.top(count) ?? Array(EmojiUsage.defaults.prefix(count))
    }
    private func react(_ emoji: String, to message: Message) {
        actions.emojiUsage?.record(emoji)
        actions.react(emoji, message)
    }
    /// The full emoji picker, for reacting to this row's message; it closes once one is picked.
    func emojiPopover() -> NSPopover? {
        guard hasActions, let message = row?.message else { return nil }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: EmojiPicker(
                frequent: quickReactions(EmojiPicker.columns),
                pick: { [weak self, weak popover] emoji in
                    self?.react(emoji, to: message)
                    popover?.close()
                },
                close: { [weak popover] in popover?.close() },
                custom: actions.customEmoji,
                pickCustom: { [actions, weak popover] emoji in
                    actions.reactCustom(emoji, message)
                    popover?.close()
                },
                loadImage: actions.loadAttachment))
        return popover
    }
    @objc func showEmojiPicker() {
        guard window != nil, let popover = emojiPopover(), let layout = rowLayout else { return }
        emojiPicker?.close()
        emojiPicker = popover
        popover.show(
            relativeTo: style == .plain ? layout.text ?? layout.bubble : layout.bubble, of: self, preferredEdge: .maxY)
    }
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
            if #available(macOS 27, *) { item.preferredImageVisibility = .visible }  // menus hide item images unless asked
            item.toolTip = source.url.host()
            item.subtitle = source.detail  // a line from it, as Google Chat's source chips show
            menu.addItem(item)
        }
        return menu
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
                        Text(step.text).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16).frame(width: 380, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }
}
