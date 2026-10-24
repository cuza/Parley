import Foundation

extension ChatStore {
    /// How a change Google refused shows once it's put back.
    enum Refusal: Equatable {
        /// One the user can simply make again (a pin, a mute, a star): a note that fades, "Couldn't <what>. <why>".
        case toast(String)
        /// One where something is lost or the user must act (leaving, deleting, taking away access): an alert to dismiss.
        case alert
    }
    /// A change Edit ▸ Undo can take back: its name as the menu shows it ("Undo Hide", "Redo Hide") and the opposite
    /// change, made through the same action, so it goes to Google too and a refusal of it shows the same way.
    struct Undoable {
        let name: String
        let reverse: @MainActor () async -> Void
        init(_ name: String, reverse: @escaping @MainActor () async -> Void) {
            self.name = name
            self.reverse = reverse
        }
    }
    /// A change shown before Google confirms it: `apply` at once, then `send`; a refusal runs `undo` and shows as `refusal`
    /// says. A cancelled call or an ended session shows as `report` shows them (nothing, or the sign-in banner).
    /// `undoable`: offered as Edit ▸ Undo, in the window the user acted in, once Google agrees, so a refused change
    /// leaves nothing to undo.
    func optimistically(
        _ refusal: Refusal, undoable: Undoable? = nil, apply: () -> Void, undo: () -> Void,
        send: () async throws -> Void
    ) async {
        apply()
        let manager = undoManager()
        do { try await send() } catch {
            undo()
            switch refusal {
            case .toast(let what): report(error, undone: what)
            case .alert: report(error)
            }
            return
        }
        guard let undoable else { return }
        if let pending = UndoEntry.pending, pending.reverse == nil {
            pending.reverse = undoable.reverse  // an Undo or Redo made this change: its entry is on the other stack already
        } else if let manager {
            UndoEntry.register(undoable.name, reverse: undoable.reverse, on: manager)
        }
    }
}

/// One change on an undo manager's stacks. Each is its own target, so an Undo or Redo Google refused takes away only
/// its own entry.
@MainActor final class UndoEntry {
    /// The entry an Undo or Redo put on the other stack, waiting for the change it runs to say what takes it back.
    @TaskLocal static var pending: UndoEntry?
    private weak var manager: UndoManager?
    fileprivate var reverse: (@MainActor () async -> Void)?

    private init(manager: UndoManager, reverse: (@MainActor () async -> Void)?) {
        self.manager = manager
        self.reverse = reverse
    }
    @discardableResult
    static func register(_ name: String, reverse: (@MainActor () async -> Void)?, on manager: UndoManager) -> UndoEntry
    {
        let entry = UndoEntry(manager: manager, reverse: reverse)
        // The handler holds the entry: UndoManager doesn't retain its targets.
        manager.registerUndo(withTarget: entry) { _ in MainActor.assumeIsolated { entry.perform(name) } }
        manager.setActionName(name)
        return entry
    }
    /// The opposite entry goes on the other stack now, while UndoManager is undoing or redoing; the change itself needs
    /// Google, so it runs afterwards and fills that entry in.
    private func perform(_ name: String) {
        guard let manager, let reverse else { return }
        let next = Self.register(name, reverse: nil, on: manager)
        Task {
            await Self.$pending.withValue(next) { await reverse() }
            // Refused, or nothing left to change (already so, or gone): nothing to redo. Removing it from its closed
            // group takes the group away too.
            if next.reverse == nil { manager.removeAllActions(withTarget: next) }
        }
    }
}
