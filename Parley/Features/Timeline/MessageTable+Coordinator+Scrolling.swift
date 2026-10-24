import AppKit
import ParleyDomain

extension MessageTable.Coordinator {
    /// The clip view's origin with the newest message resting just above the bottom inset.
    var bottomOrigin: CGFloat {
        guard let scroll, let table else { return 0 }
        return table.bounds.height + scroll.contentInsets.bottom - scroll.contentView.bounds.height
    }
    /// The part of the document not covered by the content insets (the toolbar above, the composer below).
    var uncovered: NSRect {
        guard let scroll else { return .zero }
        let insets = scroll.contentInsets
        let bounds = scroll.contentView.bounds
        return NSRect(
            x: bounds.minX, y: bounds.minY + insets.top, width: bounds.width,
            height: max(0, bounds.height - insets.top - insets.bottom))
    }
    @objc func scrolled() {
        guard let scroll, let table else { return }
        let visible = uncovered
        let clipSize = scroll.contentView.bounds.size
        if !keeping && clipSize == lastClipSize { pinnedToBottom = visible.maxY >= table.bounds.height - 40 }  // a scroll, not a resize
        lastClipSize = clipSize
        if !keeping {
            checkNearTop()
            checkNearBottom()
        }  // mid-update the offset is transient; `update` checks once it settles
        let atBottom = visible.maxY >= table.bounds.height - visible.height  // within one screen of the newest message
        if atBottom != wasAtBottom {  // after the current update: this runs while SwiftUI updates the table (keeping place)
            wasAtBottom = atBottom
            let report = parent?.atBottomChanged
            Task { @MainActor in report?(atBottom) }
        }
        if Self.reportsForUITests {  // one cheap value to poll instead of querying rows
            let middle = table.row(at: NSPoint(x: 1, y: visible.midY))
            scroll.setAccessibilityValue("\(rows.indices.contains(middle) ? rows[middle].id : "") of \(rows.count)")
        }
    }
    /// Asks for older history when the reader is within `topZone` of the top: on entering the zone, and again each time
    /// rows change while still in it, so a fast scroll keeps paging instead of stalling at the top (as Telegram does).
    /// A page that adds no rows asks nothing more until the reader leaves and re-enters the zone; the store drops
    /// requests while one is in flight or when there is no more history.
    func checkNearTop() {
        guard scroll != nil, !rows.isEmpty else {
            wasNearTop = false
            return
        }
        let visible = uncovered
        let nearTop = visible.minY < Self.topZone(visibleHeight: visible.height)
        if nearTop && (!wasNearTop || rows.count != rowsAtNearTop) {
            rowsAtNearTop = rows.count
            parent?.nearTop()
        }
        wasNearTop = nearTop
    }
    /// A detached window's end within `topZone` below the reader: asks for newer history, on entering the zone and
    /// again each time rows change while still in it.
    func checkNearBottom() {
        guard let table, parent?.detached == true, scroll != nil, !rows.isEmpty else {
            wasNearBottom = false
            return
        }
        let visible = uncovered
        let nearBottom = table.bounds.height - visible.maxY < Self.topZone(visibleHeight: visible.height)
        if nearBottom && (!wasNearBottom || rows.count != rowsAtNearBottom) {
            rowsAtNearBottom = rows.count
            parent?.nearBottom()
        }
        wasNearBottom = nearBottom
    }
    /// The highlighted message in the middle of the view, as a search result or a link opens it.
    func center(_ index: Int) {
        guard let scroll, let table else { return }
        let visible = uncovered
        let row = table.rect(ofRow: index)
        let target = min(
            max(-scroll.contentInsets.top, row.midY - visible.height / 2 - scroll.contentInsets.top), bottomOrigin)
        pinnedToBottom = false
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    /// Three screens of history above the reader, at least 600 pt.
    static func topZone(visibleHeight: CGFloat) -> CGFloat { max(600, visibleHeight * 3) }
    func scrollToBottom() {
        guard let scroll, table != nil else { return }
        pinnedToBottom = true
        let target = NSPoint(x: 0, y: max(-scroll.contentInsets.top, bottomOrigin))
        // An animation only advances with frames on screen: hidden, occluded or locked, jump instead of stalling.
        // With Reduce Motion, jump too.
        guard scroll.window?.occlusionState.contains(.visible) == true,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            scroll.contentView.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { _ in scroll.contentView.animator().setBoundsOrigin(target) }
    }
}
