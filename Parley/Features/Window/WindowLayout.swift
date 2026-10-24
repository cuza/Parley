import AppKit
import ParleyDomain
import SwiftUI

/// The window's widths: the sidebar, the timeline's minimum and the side pane, and how the window makes room for them.
extension ChatView {
    /// A side pane beside the timeline: Info, an open thread, or the threads list where the conversation has threads.
    /// The window's minimum width and the room made for it follow this, as the split view does.
    static func paneShown(_ pane: SidePane, room: Conversation?) -> Bool {
        pane.person != nil || pane.info || pane.thread != nil || (pane.threads && room.map(offersThreads) == true)
    }
    /// `paneWidth` is the side pane's narrowest (and first) width; dragging its divider widens it up to `paneMaxWidth`.
    /// The sidebar's bounds take effect only as the column's outermost modifier: under another, the split view ignores them.
    static let paneWidth: CGFloat = 340, paneMaxWidth: CGFloat = 560, timelineMinWidth: CGFloat = 380,
        sidebarMinWidth: CGFloat = 180, sidebarMaxWidth: CGFloat = 300
    /// What the shown areas need: the sidebar at its width (0 when hidden), the timeline's minimum and, while open, the
    /// side pane. The split view keeps the sidebar's width as the window narrows and would clip the rest.
    static func minWidth(paneOpen: Bool, sidebar: CGFloat) -> CGFloat {
        sidebar + timelineMinWidth + (paneOpen ? 1 + paneWidth : 0)
    }
    /// As Mail does: a window too narrow for the sidebar hides it, and gives it back once it is wide enough again,
    /// unless the user hid it themselves.
    static func sidebar(width: CGFloat, paneOpen: Bool, sidebarWidth: CGFloat, visible: Bool, autoHidden: Bool) -> (
        visible: Bool, autoHidden: Bool
    ) {
        let fits = width >= minWidth(paneOpen: paneOpen, sidebar: sidebarWidth)
        if visible, !fits { return (false, true) }
        if !visible, autoHidden, fits { return (true, false) }
        return (visible, autoHidden && !visible)
    }
    /// The sidebar's width as the window's needs count it: none in a conversation's own window or while hidden.
    static func shownSidebar(
        fixedConversation: ConversationID?, columns: NavigationSplitViewVisibility, measured: CGFloat
    ) -> CGFloat {
        fixedConversation != nil || columns == .detailOnly ? 0 : measured
    }
    /// The window's width once a pane opens: grown only by what the shown areas lack.
    static func widthForPane(window: CGFloat, sidebar: CGFloat) -> CGFloat {
        max(window, minWidth(paneOpen: true, sidebar: sidebar))
    }
    /// Widens the window to `wanted` (within the screen), if it is narrower.
    /// Only `window`, the view's own: every window shares the store, so each sees a pane open and must not resize another.
    static func makeRoom(_ wanted: CGFloat, in window: NSWindow?, animate: Bool = true) {
        guard let window, window.frame.width < wanted else { return }
        var frame = window.frame
        frame.size.width = min(wanted, window.screen?.visibleFrame.width ?? wanted)
        if let screen = window.screen?.visibleFrame { frame.origin.x = min(frame.origin.x, screen.maxX - frame.width) }
        window.setFrame(frame, display: true, animate: animate)
    }
}

/// The window a view is in, held weakly.
final class WindowRef { weak var window: NSWindow? }
/// A width kept outside SwiftUI's state, so changing it redraws nothing.
final class WidthRef { var value: CGFloat = 0 }
/// Records its view's window in `ref` once it is in one, hands it to `appeared`, and keeps its title at `title` when set.
struct WindowReader: NSViewRepresentable {
    let ref: WindowRef
    var title: String?
    var appeared: ((NSWindow) -> Void)?
    func makeNSView(context: Context) -> NSView { Reader(ref: ref, appeared: appeared) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Reader)?.title = title
        if let title, let window = view.window, window.title != title { window.title = title }
    }
    final class Reader: NSView {
        let ref: WindowRef
        let appeared: ((NSWindow) -> Void)?
        var title: String?
        private var watch: NSKeyValueObservation?
        init(ref: WindowRef, appeared: ((NSWindow) -> Void)?) {
            self.ref = ref
            self.appeared = appeared
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref.window = window
            watch = nil
            guard let window else { return }
            if let title { window.title = title }  // before it joins a tab group, so the tab shows the name
            // SwiftUI sets the scene's window title back to the app's name after this, at a moment that varies: put
            // the name back each time, so the tab and the Window menu show it.
            watch = window.observe(\.title) { [weak self] window, _ in
                MainActor.assumeIsolated { if let title = self?.title, window.title != title { window.title = title } }
            }
            appeared?(window)
        }
    }
}

/// A conversation opened in its own window joins the conversation window already open as a tab, as Safari's windows
/// do with "Prefer tabs", unless Settings ▸ General turns that off; the main window and thread windows stay apart.
@MainActor enum ConversationTabs {
    static let identifier = "dev.cuza.Parley.conversation"
    static let key = "conversationWindowsAsTabs"
    static var asTabs: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static func join(_ window: NSWindow, among windows: [NSWindow], asTab: Bool = asTabs) {
        window.tabbingIdentifier = identifier  // Window ▸ Merge All Windows joins conversation windows either way
        guard asTab, window.tabbedWindows == nil,
            let host = windows.first(where: { $0 !== window && $0.isVisible && $0.tabbingIdentifier == identifier })
        else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}
