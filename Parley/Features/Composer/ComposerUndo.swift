import AppKit

/// The composer's own Edit ▸ Undo: its typing, kept apart from the window's stack so Parley can forget it whenever
/// it replaces the text itself (a sent message, another draft). With no typing left to undo or redo, Undo and Redo go
/// on to the window's stack (a pin, a mute), as if the field shared it.
final class ComposerUndoManager: UndoManager {
    /// The window's stack.
    var next: () -> UndoManager? = { nil }

    private var undoesTyping: Bool { super.canUndo }
    private var redoesTyping: Bool { super.canRedo }
    override var canUndo: Bool { undoesTyping || next()?.canUndo == true }
    override var canRedo: Bool { redoesTyping || next()?.canRedo == true }
    override func undo() {
        if undoesTyping { super.undo() } else { next()?.undo() }
    }
    override func redo() {
        if redoesTyping { super.redo() } else { next()?.redo() }
    }
    override var undoMenuItemTitle: String {
        undoesTyping ? super.undoMenuItemTitle : next()?.undoMenuItemTitle ?? super.undoMenuItemTitle
    }
    override var redoMenuItemTitle: String {
        redoesTyping ? super.redoMenuItemTitle : next()?.redoMenuItemTitle ?? super.redoMenuItemTitle
    }
}
