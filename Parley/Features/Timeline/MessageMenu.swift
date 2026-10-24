import AppKit

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
        self.emoji = emoji
        self.react = react
        self.more = more
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
            .withSymbolConfiguration(
                .init(pointSize: 20, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))
        if let symbol {
            moreButton.image = symbol
            moreButton.imagePosition = .imageOnly
        } else {
            moreButton.title = "+"
            moreButton.font = .systemFont(ofSize: 22)
        }
        moreButton.target = self
        moreButton.action = #selector(showMore)
        moreButton.frame = NSRect(x: 7 + CGFloat(emoji.count) * 36, y: 3, width: 36, height: 32)
        moreButton.setAccessibilityLabel("More reactions")
        moreButton.toolTip = "More Reactions"
        addSubview(moreButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped(_ sender: NSButton) { react(emoji[sender.tag]) }
    @objc private func showMore() { more() }
}
