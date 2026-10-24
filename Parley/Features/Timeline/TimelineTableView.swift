import AppKit
import Quartz

/// The timeline's table: offers trackpad scroll events to the reply swipe before scrolling, and controls the
/// Quick Look panel for its attachments (Space toggles it, as in Finder).
final class TimelineTableView: NSTableView {
    var swipeHandler: ((NSEvent) -> Bool)?
    weak var files: AttachmentFiles?
    /// What a key does to the selected message; the coordinator decides (it knows whose message it is).
    enum Key { case reply, quote, edit, delete, copy }
    var act: ((Key, Int) -> Void)?
    /// From the composer (⌘↑): the newest message, selected and in view.
    func selectLast() {
        guard numberOfRows > 0 else { return }
        selectRowIndexes([numberOfRows - 1], byExtendingSelection: false)
        scrollRowToVisible(numberOfRows - 1)
    }
    /// Back to the composer under this list (Esc, or after starting a quote or an edit).
    func leave() {
        deselectAll(nil)
        window?.makeFirstResponder(ComposerTextView.nearest(to: self))
    }
    /// The list over `view` (the composer under it): in the same pane, side by side with others in the window.
    static func nearest(to view: NSView) -> TimelineTableView? {
        guard let content = view.window?.contentView else { return nil }
        let x = view.convert(NSPoint(x: view.bounds.midX, y: 0), to: nil).x
        func tables(_ view: NSView) -> [TimelineTableView] {
            ((view as? TimelineTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
        }
        return tables(content).first { table in
            let frame = (table.enclosingScrollView ?? table).convert(
                (table.enclosingScrollView ?? table).bounds, to: nil)
            return frame.minX <= x && x <= frame.maxX
        }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { deselectAll(nil) }  // the selection is the keyboard's place in the list; it goes when the keyboard does
        return resigned
    }
    @objc func copy(_ sender: Any?) { if selectedRow >= 0 { act?(.copy, selectedRow) } }
    override func scrollWheel(with event: NSEvent) {
        if swipeHandler?(event) != true { super.scrollWheel(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", files?.togglePreview() == true { return }
        if event.keyCode == 53 {
            leave()
            return
        }  // Esc
        if selectedRow >= 0, event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]) {
            let key: Key? =
                switch event.keyCode {
                case 36, 76: .reply  // Return, Enter
                case 51, 117: .delete  // Delete, Forward Delete
                default:
                    switch event.charactersIgnoringModifiers {
                    case "r": .quote
                    case "e": .edit
                    default: nil
                    }
                }
            if let key {
                act?(key, selectedRow)
                return
            }
        }
        super.keyDown(with: event)  // ↑ ↓ Home End Page Up/Down: the table's own
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { files?.previewItems.isEmpty == false }
    }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { files?.beginControl(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { files?.endControl(panel) }
    }
}
