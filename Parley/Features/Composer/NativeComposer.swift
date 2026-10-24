import AppKit
import ParleyDomain
import SwiftUI

/// The message field: rich text whose formatting travels as `TextStyleRange`s beside the plain draft text.
struct NativeComposer: NSViewRepresentable {
    var text: String
    var formatting: [TextStyleRange] = []
    var change: (String, [TextStyleRange]) -> Void
    var send: () -> Void
    var editLast: () -> Void
    var cancel: () -> Void
    var attach: ([URL]) -> Void = { _ in }
    var members: [Person] = []  // who `@` can mention
    var spaces: [Conversation] = []  // what a pasted Chat link can become the chip of
    var needMembers: () -> Void = {}  // asked when a mention starts, to load the full member list
    var customEmoji: [CustomEmoji] = []  // what `:shortcode` suggests
    var needCustomEmoji: () -> Void = {}  // asked when a `:shortcode` starts, to load the organisation's list
    var searchCustomEmoji: (String) -> Void = { _ in }  // asked as a `:shortcode` is typed, with the text after the ":"
    var directoryPeople = Found<Person>()  // the @ list's People beyond the members, from the directory
    var mentionApps = Found<Person>()  // its Apps section: the conversation's own apps
    var driveFiles = Found<DriveFile>()  // its Files section
    var needMentionResults: (String) -> Void = { _ in }  // asked as an @ query is typed, with the text after the "@"
    var slashCommands: [SlashCommand] = []  // what a "/" at the start suggests
    var needSlashCommands: (String) -> Void = { _ in }  // asked as a "/command" is typed, with the text after the "/"
    var runCommand: (SlashCommand) -> Void = { _ in }  // a picked quick command or Google Chat action
    var loadImage: (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }  // custom emoji pictures
    var focus: String?  // the field takes focus each time this changes to a new non-nil value
    var handle: ComposerHandle?  // for controls beside the field that act on it
    var height: (CGFloat) -> Void = { _ in }  // the laid-out text height, whenever it changes
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(delegate: context.coordinator) }
    static func makeScrollView(delegate: (any NSTextViewDelegate)?) -> NSScrollView {
        let scroll = NSScrollView()
        let view = ComposerTextView(usingTextLayoutManager: false)  // TextKit 1: list bullets are drawn from the layout manager
        view.delegate = delegate
        view.isRichText = true
        view.usesFontPanel = false
        view.importsGraphics = false
        view.allowsUndo = true  // on its own stack, `ComposerUndoManager`
        view.typingAttributes = ComposerTextView.visual([:])
        NotificationCenter.default.addObserver(
            view, selector: #selector(ComposerTextView.textSizeChanged), name: TextSize.changed, object: nil)
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        // Writing Tools rewrite as plain text: a rich result's fonts would show formatting the draft doesn't carry.
        if #available(macOS 15.2, *) { view.allowedWritingToolsResultOptions = .plainText }
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityIdentifier("composer")
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true  // legacy scrollers ("Show scroll bars: Always", a mouse) only once the draft overflows
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        handle?.view = view
        if let handle { view.askForLink = { [weak handle] in handle?.askForLink?() } }
        view.loadImage = loadImage
        if view.acceptsReload, view.draftText != text || Set(view.formatting) != Set(formatting) {
            view.load(text, formatting)
        }
        view.send = send
        view.editLast = editLast
        view.cancel = cancel
        view.attach = attach
        let report = height
        view.heightChanged = { height in DispatchQueue.main.async { report(height) } }  // never mutates state inside this update
        view.needMembers = needMembers
        view.needCustomEmoji = needCustomEmoji
        view.searchCustomEmoji = searchCustomEmoji
        view.needMentionResults = needMentionResults
        if view.directoryPeople != directoryPeople { view.directoryPeople = directoryPeople }
        if view.mentionApps != mentionApps { view.mentionApps = mentionApps }
        if view.driveFiles != driveFiles { view.driveFiles = driveFiles }
        if view.mentionPeople != members { view.mentionPeople = members }
        view.chipConversations = spaces
        if view.customEmoji != customEmoji { view.customEmoji = customEmoji }
        view.needSlashCommands = needSlashCommands
        view.runCommand = runCommand
        if view.slashCommands != slashCommands { view.slashCommands = slashCommands }
        if focus != context.coordinator.focus {
            context.coordinator.focus = focus
            if focus != nil { view.takeKeyboard() }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var focus: String?
        init(_ parent: NativeComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? ComposerTextView { parent.change(view.draftText, view.formatting) }
        }
    }
}
/// The composer's field for the controls beside it: the emoji button's picker inserts into it.
@MainActor final class ComposerHandle {
    weak var view: ComposerTextView?
    /// Shows the link form (⌘K, the bar's link button, Format ▸ Link…).
    var askForLink: (() -> Void)?
    /// The selected text, to start the link form with.
    var selectedText: String { view.map { ($0.string as NSString).substring(with: $0.selectedRange()) } ?? "" }
    /// Puts the form's link in and gives the field back the focus.
    func link(_ url: URL, text: String) {
        guard let view else { return }
        view.link(url, text: text.isEmpty ? nil : text)
        view.window?.makeFirstResponder(view)
    }
    /// Shared with reactions: one most-used list, so the picker opens on the emoji I use anywhere.
    let usage: EmojiUsage
    init(usage: EmojiUsage = EmojiUsage()) { self.usage = usage }
    // ponytail: custom emoji are not counted, so never in "Frequently Used"; EmojiUsage keys are plain strings.
    /// The picker for the emoji button: a pick replaces the selection (typed in, so it takes the typing style and the
    /// formatting after it moves along), is counted, closes the picker and gives the field back the focus.
    /// A custom emoji goes in as its picture.
    func emojiPicker(
        custom: (() -> [CustomEmoji])? = nil,
        loadImage: @escaping (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() },
        close: @escaping () -> Void
    ) -> EmojiPicker {
        EmojiPicker(
            frequent: usage.top(EmojiPicker.columns),
            pick: { [weak self] emoji in
                guard let self else { return }
                usage.record(emoji)
                if let view {
                    view.insertText(emoji, replacementRange: view.selectedRange())
                    view.window?.makeFirstResponder(view)
                }
                close()
            }, close: close, custom: custom,
            pickCustom: { [weak self] emoji in
                if let view = self?.view {
                    view.insertCustomEmoji(emoji, replacing: view.selectedRange())
                    view.window?.makeFirstResponder(view)
                }
                close()
            }, loadImage: loadImage)
    }
}

/// The composer being typed in, for the Format menu: its items act on it, and are off when there is none.
@MainActor @Observable final class ComposerFocus {
    static let shared = ComposerFocus()
    var composer: ComposerTextView?
}
