import AppKit
import Testing

@testable import Parley

/// Edit ▸ Undo in the composer takes back typing. Text Parley puts there itself (a sent message cleared, a draft
/// loaded) can't be undone back, and what was undoable before the typing (a pin, a mute) still is.
@MainActor struct ComposerUndoTests {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
        defer: false)
    private let view: ComposerTextView
    private let undo: UndoManager  // what Edit ▸ Undo uses while the composer has focus

    init() throws {
        window.isReleasedWhenClosed = false
        let scroll = NativeComposer.makeScrollView(delegate: nil)
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        window.contentView?.addSubview(scroll)
        view = try #require(scroll.documentView as? ComposerTextView)
        window.makeFirstResponder(view)
        undo = try #require(view.undoManager)
        for manager in [undo, window.undoManager] { manager?.groupsByEvent = false }
    }
    private func step(_ manager: UndoManager?, _ change: () -> Void) {
        manager?.beginUndoGrouping()
        change()
        manager?.endUndoGrouping()
    }
    private func type(_ text: String) {
        step(undo) { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
    private final class Pin { var pinned = true }
    /// A quick change the store registers on the window's stack, as pinning does.
    private func pin() throws -> Pin {
        let pin = Pin()
        let window = try #require(window.undoManager)
        step(window) { window.registerUndo(withTarget: pin) { $0.pinned = false } }
        return pin
    }

    @Test func undoTakesBackTyping() {
        type("hello")
        #expect(view.string == "hello")
        undo.undo()
        #expect(view.string == "")
    }

    @Test func aSentMessageCantBeUndoneBack() {
        type("on my way")
        view.load("", [])  // what the composer shows once the message is sent
        #expect(!undo.canUndo)
        #expect(view.string == "")
    }

    @Test func aQuickChangeBeforeTheTypingIsStillUndoable() throws {
        let pin = try pin()
        type("draft")
        view.load("", [])
        #expect(undo.canUndo)
        undo.undo()
        #expect(!pin.pinned)
        #expect(view.string == "")
    }

    @Test func typingIsUndoneBeforeTheQuickChange() throws {
        let pin = try pin()
        type("draft")
        undo.undo()
        #expect(view.string == "" && pin.pinned)
        undo.undo()
        #expect(!pin.pinned)
    }
}
