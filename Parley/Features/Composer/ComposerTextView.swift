import AppKit
import ParleyDomain

/// The message field's text view: keys, paste and drops, focus and list bullets here; formatting and tokens (mentions,
/// chips, commands, custom emoji) in its extensions.
final class ComposerTextView: NSTextView {
    var send: (() -> Void)?
    var heightChanged: ((CGFloat) -> Void)?
    fileprivate var reportedHeight: CGFloat = 0
    override func layout() {
        super.layout()
        reportHeight()
    }  // the first real width, and every resize
    var editLast: (() -> Void)?
    var cancel: (() -> Void)?
    /// False while an input method has unfinished text (an accent being typed, an inline prediction): replacing the text
    /// then would make the composition land in the new text and repeat words. The store's change waits for the next update.
    var acceptsReload: Bool { !hasMarkedText() }
    /// Asks for a link's address (and text, with nothing selected); the composer's owner shows the form, then calls `link`.
    var askForLink: (() -> Void)?

    // MARK: Mentions and custom emoji: the lists and the picker (ComposerTextView+Tokens.swift)

    /// The conversation's apps' commands, for a "/" at the start; `needSlashCommands` asks for those matching what's typed.
    var slashCommands: [SlashCommand] = [] { didSet { updateMention() } }
    var needSlashCommands: ((String) -> Void)?
    /// A picked entry that isn't sent as a "/name" (a quick command, "Send a Meet link").
    var runCommand: ((SlashCommand) -> Void)?
    /// Conversations a pasted Chat link can become the chip of: the account's.
    var chipConversations: [Conversation] = [] { didSet { if chipConversations != oldValue { updateMention() } } }
    var mentionPeople: [Person] = [] { didSet { updateMention() } }
    var needMembers: (() -> Void)?
    var mentionQuery: MentionQuery?
    var mentionMatches: [Suggestion] = []
    var mentionSelection = 0
    var dismissedMention: Int?  // where the `@` closed with Esc is; it stays closed until another `@`
    let mentionPopup = MentionPopup()
    var customEmoji: [CustomEmoji] = [] { didSet { updateMention() } }
    var needCustomEmoji: (() -> Void)?
    var searchCustomEmoji: ((String) -> Void)?
    var directoryPeople = Found<Person>() { didSet { updateMention() } }
    var driveFiles = Found<DriveFile>() { didSet { updateMention() } }
    var mentionApps = Found<Person>() { didSet { updateMention() } }
    var needMentionResults: ((String) -> Void)?
    var loadImage: (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }
    var imageTask: Task<Void, Never>?
    lazy var emojiAnimation = EmojiAnimation(self) { [weak self] in self?.needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { return super.keyDown(with: event) }  // an input method's composition owns Return, Esc and the arrows
        if mentionQuery != nil, !mentionMatches.isEmpty {
            let count = mentionMatches.count
            switch event.keyCode {
            case 125:
                mentionSelection = (mentionSelection + 1) % count
                showMentions()
                return  // ↓
            case 126:
                mentionSelection = (mentionSelection + count - 1) % count
                showMentions()
                return  // ↑
            case 48:
                insert(mentionMatches[mentionSelection], replacing: mentionQuery!.range)
                return  // Tab
            case 36, 76:  // Return, Enter; a link's chip takes Tab only, as on web, so Return still sends
                if mentionQuery?.chip == nil {
                    insert(mentionMatches[mentionSelection], replacing: mentionQuery!.range)
                    return
                }
            case 53:
                dismissedMention = mentionQuery?.range.location
                updateMention()
                return  // Esc
            default: break
            }
        }
        // Return sends; ⇧Return and ⌥Return add a line, as in Messages.
        if event.keyCode == 36 && event.modifierFlags.isDisjoint(with: [.shift, .option]) {
            send?()
            return
        }
        // ⌘↑: up into the messages, as Tab goes from Mail's search field to its list; the newest is selected.
        if event.keyCode == 126, event.modifierFlags.contains(.command), let table = TimelineTableView.nearest(to: self)
        {
            window?.makeFirstResponder(table)
            table.selectLast()
            return
        }
        if event.keyCode == 126 && string.isEmpty {
            editLast?()
            return
        }
        if event.keyCode == 53 {
            cancel?()
            return
        }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.firstResponder === self, modifiers.contains(.command), !modifiers.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == [.command, .shift, .option], event.charactersIgnoringModifiers?.lowercased() == "c" {
            toggle(.codeBlock)
            return true
        }
        guard !modifiers.contains(.option) else { return super.performKeyEquivalent(with: event) }
        let style: TextStyleRange.Style? =
            switch (
                modifiers.contains(.shift), event.keyCode == 28 ? "8" : event.charactersIgnoringModifiers?.lowercased()
            ) {
            case (false, "b"): .bold
            case (false, "i"): .italic  // Conversation Info is ⇧⌘I
            case (false, "u"): .underline
            case (true, "x"): .strike
            case (true, "c"): .code
            case (false, "'"): .quote  // Mail's quote key; ⇧⌘I is Conversation Info
            case (true, "8"): .listItem  // key code 28 is the 8 key, whatever shift makes of it
            default: nil
            }
        // ⇧⌘K: ⌘K is Jump to Conversation everywhere, the composer too, as in chat apps.
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "k", let askForLink {
            askForLink()
            return true
        }
        guard let style else { return super.performKeyEquivalent(with: event) }
        toggle(style)
        return true
    }
    /// Foreign styles never come in: paste and drops take plain text, which picks up the typing attributes.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// Files and images pasted or dropped here become attachments instead of text.
    var attach: (([URL]) -> Void)?
    var clipboard = NSPasteboard.general

    /// Edit ▸ Undo's typing, on the composer's own stack, which goes on to the window's when it runs out.
    lazy var typingUndo: ComposerUndoManager = {
        let undo = ComposerUndoManager()
        undo.next = { [weak self] in self?.window?.undoManager }
        return undo
    }()
    override var undoManager: UndoManager? { typingUndo }
    /// Screenshot thumbnails, Photos, browsers and our own timeline drag images as file promises rather than files.
    private static let fileTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }
    override func paste(_ sender: Any?) {
        if let attach, let files = Self.files(on: clipboard) { attach(files) } else { super.paste(sender) }
    }
    /// Continuity Camera's Insert from iPhone (a photo, a scan, a sketch) in the field's menu: the picture joins the draft
    /// as an attachment, as a pasted one does. `importsGraphics` stays off, so the text view itself never asks for one.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == nil, let returnType, [.png, .tiff].contains(returnType), attach != nil { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let attach, let files = Self.files(on: pasteboard) {
            attach(files)
            return true
        }
        return super.readSelection(from: pasteboard)
    }
    /// The text view enables Paste only for the types it reads (plain text), so an image on the clipboard needs saying so here.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), attach != nil, Self.hasFiles(on: clipboard) { return true }
        return super.validateMenuItem(item)
    }
    static func hasFiles(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.string]) == nil && pasteboard.availableType(from: [.png, .tiff]) != nil
    }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Self.fileTypes + super.acceptableDragTypes }
    override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation
    {
        Self.fileTypes.contains(type) ? .copy : super.dragOperation(for: dragInfo, type: type)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let attach else { return super.performDragOperation(sender) }
        if let files = Self.files(on: sender.draggingPasteboard) {
            attach(files)
            return true
        }
        guard
            let promises = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
                as? [NSFilePromiseReceiver],
            !promises.isEmpty
        else { return super.performDragOperation(sender) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return false
        }
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                if error == nil { MainActor.assumeIsolated { attach([url]) } }
            }
        }
        return true
    }
    /// Copied or dragged files as they are; image data (screenshots, copied images) saved as a PNG in a temporary folder.
    /// Nil when there are neither, or when there is text and no files: copied text may carry a picture of itself.
    static func files(on pasteboard: NSPasteboard) -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty
        {
            return urls
        }
        guard pasteboard.availableType(from: [.string]) == nil,
            let png = pasteboard.data(forType: .png)
                ?? pasteboard.data(forType: .tiff).flatMap({
                    NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
                })
        else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
        let file = folder.appending(path: "Pasted image.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch { return nil }
        return [file]
    }

    /// Right-click: a Format submenu after Paste, every format with its shortcut, as Telegram's composer offers.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let format = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        format.submenu = formatMenu()
        let at = menu.items.firstIndex { $0.action == #selector(paste(_:)) }.map { $0 + 1 } ?? 0
        menu.insertItem(format, at: at)
        menu.insertItem(.separator(), at: at)
        // Vertical text has no place in a message field, and the composer's layout breaks with it.
        let orientation = #selector(changeLayoutOrientation(_:))
        menu.items.filter {
            $0.submenu?.items.contains { $0.action == orientation } == true || $0.action == orientation
        }
        .forEach(menu.removeItem)
        return menu
    }
    /// The field stays horizontal, whatever sends this.
    override func changeLayoutOrientation(_ sender: Any?) {}
    /// What is typed next never extends a token.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            let tokens = Set(Self.tokenKeys + [Self.customEmojiKey, .attachment])
            super.typingAttributes =
                newValue.keys.contains(where: tokens.contains)
                ? Self.visual(newValue.filter { !tokens.contains($0.key) }) : newValue
        }
    }
    /// Backspace or forward delete next to a token removes all of it.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, caret.location > 0, let token = mentionRange(at: caret.location - 1) {
            setSelectedRange(token)
        }
        super.deleteBackward(sender)
    }
    override func deleteForward(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, let token = mentionRange(at: caret.location) { setSelectedRange(token) }
        super.deleteForward(sender)
    }
    override func didChangeText() {
        defer { reportHeight() }
        if let storage = textStorage {  // a token edited inside, or cut in part, becomes plain text
            for key in Self.tokenKeys {
                var broken: [NSRange] = []
                storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    // A command is one only as the message's first word.
                    let text =
                        (value as? MentionToken)?.text ?? (value as? DriveFile)?.title
                        ?? (value as? SlashCommand).flatMap { range.location == 0 ? $0.name : nil }
                    if value != nil, (storage.string as NSString).substring(with: range) != text {
                        broken.append(range)
                    }
                }
                for range in broken {
                    storage.removeAttribute(key, range: range)
                    Self.restyle(storage, in: range)
                }
            }
        }
        super.didChangeText()
        updateMention()
        if emojiAnimation.playing { emojiAnimation.update(customEmojiPictures) }  // the last one deleted: stop
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { updateMention() }
    }
    /// Set while the composer has been asked for the keyboard but isn't in a window to take it.
    private var wantsKeyboard = false
    /// Takes the keyboard now, or as soon as the composer is in its window: one made with a focus (a thread's, as it
    /// opens) can join its window a few run-loop turns later.
    func takeKeyboard() {
        if let window {
            window.makeFirstResponder(self)
            wantsKeyboard = false
        } else {
            wantsKeyboard = true
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // After this change of window settles: making it first responder from inside the move doesn't stick.
        if wantsKeyboard, window != nil { DispatchQueue.main.async { [weak self] in self?.takeKeyboard() } }
    }
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { ComposerFocus.shared.composer = self }
        return became
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            mentionPopup.close()
            if ComposerFocus.shared.composer === self { ComposerFocus.shared.composer = nil }
        }
        return resigned
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { mentionPopup.close() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// List bullets sit in each item's indent. They are drawn, not typed, so the sent text stays marker-free.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, let manager = layoutManager else { return }
        let string = storage.string as NSString
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let bullet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14 * TextSize.scale), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        storage.enumerateAttribute(Self.key(.listItem), in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard value != nil else { return }
            string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, line, _ in
                let fragment = manager.lineFragmentRect(
                    forGlyphAt: manager.glyphIndexForCharacter(at: line.location), effectiveRange: nil)
                ("•" as NSString).draw(
                    at: NSPoint(x: origin.x + padding + 3, y: origin.y + fragment.minY), withAttributes: bullet)
            }
        }
    }
}

extension ComposerTextView {
    /// The composer under `view` (a list), in the same pane: where Esc in the list goes back to.
    static func nearest(to view: NSView) -> ComposerTextView? {
        let x = view.convert(NSPoint(x: view.bounds.midX, y: 0), to: nil).x
        return all(in: view.window).first { composer in
            let frame = composer.convert(composer.bounds, to: nil)
            return frame.minX <= x && x <= frame.maxX
        }
    }
}

extension ComposerTextView {
    /// A window's composers, in view order.
    static func all(in window: NSWindow?) -> [ComposerTextView] {
        func composers(_ view: NSView) -> [ComposerTextView] {
            ((view as? ComposerTextView).map { [$0] } ?? []) + view.subviews.flatMap(composers)
        }
        return window?.contentView.map(composers) ?? []
    }
}

extension ComposerTextView {
    /// The field's height for its wrapped text, so one long paragraph grows it the way several lines do.
    var contentHeight: CGFloat {
        guard let manager = layoutManager, let container = textContainer else { return 0 }
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + textContainerInset.height * 2
    }
    func reportHeight() {
        guard bounds.width > 0 else { return }  // not laid out yet: everything would wrap
        let height = contentHeight
        guard height != reportedHeight else { return }
        reportedHeight = height
        heightChanged?(height)
    }
}
