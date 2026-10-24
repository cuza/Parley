import ParleyDomain
import SwiftUI

/// The main window's actions for the menu bar; each acts on the window in front.
struct ChatCommands {
    var find: (() -> Void)?  // nil in a conversation's own window
    var jump: () -> Void
    var info: () -> Void
    var editLast: () -> Void
    var unread: (_ forward: Bool) -> Void
    /// The conversation on screen, which the Conversation menu acts on; nil on Home and the other shortcuts.
    var room: Conversation?
    var threads: (() -> Void)?  // nil where the conversation has no threads
    var threadsShown = false  // the Threads list is on screen, for the item's title
    var openInWindow: (() -> Void)?
    var newSection: (() -> Void)?
    var leave: (() -> Void)?  // asks first
    var block: (() -> Void)?  // asks first
    var attach: (() -> Void)?
}
extension FocusedValues {
    @Entry var chatCommands: ChatCommands?
    /// Conversation ▸ Open in New Window for what has the keyboard, over the conversation on screen: the rows selected in
    /// Home, Mentions or Starred, or the thread pane.
    @Entry var openFocusedInWindow: FocusedOpen?
    /// The focused window's conversation, for File ▸ Send a Meet Link.
    @Entry var meetLinkConversation: ConversationID?
}
/// What Open in New Window opens for the view with the keyboard, and the menu item's title for it.
struct FocusedOpen {
    var title = "Open in New Window"
    var open: () -> Void
}
