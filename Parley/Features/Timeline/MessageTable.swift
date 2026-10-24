import AppIntents
import AppKit
import ParleyDomain
import SwiftUI

/// The message list, laid out like Telegram for macOS's chat: every row's height and
/// element frames come from a `RowLayout` computed for the table width, rows are frame-laid-out AppKit views
/// (`MessageRowView`), updates are diffs (older pages inserted above, new messages appended), and after every change
/// the first visible row is put back at its exact offset, or the view stays at the bottom when the reader was there.
struct MessageTable: NSViewRepresentable {
    let rows: [TimelineRow]
    let meID: PersonID
    let kind: ConversationKind
    var style = TimelineStyle.bubbles
    /// The wallpaper and bubble colour settings: rows redraw when either changes.
    var look = ""
    var highlighted: MessageID?
    var identifier = "timeline"
    let actions: MessageRowActions
    /// Called when the reader scrolls into the top zone (three screens, `Coordinator.topZone`), and again after each
    /// change to the rows while still in it.
    let nearTop: () -> Void
    /// A detached window (opened at an old message) near its bottom: asks for newer history, as `nearTop` asks for older.
    var nearBottom: () -> Void = {}
    /// The rows are a window away from the newest messages: newer pages land below without pulling the reader down.
    var detached = false
    /// Whether the newest message is within a screen; drives the scroll-to-bottom button.
    var atBottomChanged: (Bool) -> Void = { _ in }
    /// Bumped to scroll smoothly to the newest message (the scroll-to-bottom button).
    var scrollRequest = 0
    /// Height of what floats over the bottom of the timeline (the composer): the newest message rests just above it.
    var bottomInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(context.coordinator, identifier: identifier)
    }
    static func makeScrollView(_ coordinator: Coordinator, identifier: String) -> NSScrollView {
        let table = TimelineTableView()
        table.swipeHandler = { [weak coordinator] event in coordinator?.handleSwipe(event) ?? false }
        table.act = { [weak coordinator, weak table] key, row in
            if let table { coordinator?.act(key, on: row, in: table) }
        }
        table.files = coordinator.files
        coordinator.files.responder = table
        coordinator.files.messages = { [weak coordinator] in coordinator?.rows.map(\.message) ?? [] }
        table.addTableColumn(NSTableColumn(identifier: .init("message")))
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero  // gaps are part of each RowLayout
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = coordinator
        table.delegate = coordinator
        if #available(macOS 27, *) { table.appIntentsDataSource = coordinator }  // Siri sees which message each row is
        let scroll = NSScrollView()
        scroll.documentView = table
        // The table sizes its own height to its rows. Under SwiftUI its autoresizing mask becomes constraints, and a
        // layout pass then writes back a height from before the rows were re-measured, hiding the newest under the composer.
        table.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true  // no empty legacy scroller track beside a short conversation
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false  // the bottom inset follows the composer (`bottomInset`)
        scroll.contentView.automaticallyAdjustsContentInsets = false  // the clip view would otherwise reset it to the safe area
        scroll.setAccessibilityIdentifier(identifier)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        table.postsFrameChangedNotifications = true  // the table's own width, which settles after the clip view's
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.tableResized), name: NSView.frameDidChangeNotification,
            object: table)
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.liveResizeEnded), name: NSWindow.didEndLiveResizeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.pictureSized), name: CardLayout.pictureSized, object: nil)
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.textSizeChanged), name: TextSize.changed, object: nil)
        coordinator.scroll = scroll
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
}
