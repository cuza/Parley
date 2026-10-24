import ParleyDomain
import SwiftUI

/// The window's shortcuts as menu items, so the menus and Help's search list them.
struct ChatMenuCommands: Commands {
    let store: ChatStore
    @FocusedValue(\.chatCommands) private var chat
    @FocusedValue(\.openFocusedInWindow) private var openFocused
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Messages…") { chat?.find?() }.keyboardShortcut("f").disabled(chat?.find == nil)
            Button("Edit Last Message") { chat?.editLast() }.keyboardShortcut("e").disabled(chat == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Conversation Info") { chat?.info() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(
                chat == nil)
            Divider()
            // As Mail's: message text in the timeline and composer, saved as a setting.
            Button("Actual Size") { TextSize.set(1) }.keyboardShortcut("0")
            Button("Bigger") { TextSize.set(TextSize.next(from: TextSize.scale, by: 1)) }.keyboardShortcut("+")
            Button("Smaller") { TextSize.set(TextSize.next(from: TextSize.scale, by: -1)) }.keyboardShortcut("-")
        }
        CommandGroup(after: .newItem) {
            // As Safari's: a tab beside the conversation window in front, showing the conversation palette.
            Button("New Tab") { NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) }
                .keyboardShortcut("t")
            Divider()
            Button("Attach Files…") { chat?.attach?() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(
                chat?.attach == nil)
        }
        CommandMenu("Go") {
            Button("Back") { Task { await store.goBack() } }.keyboardShortcut("[").disabled(!store.canGoBack)
            Button("Forward") { Task { await store.goForward() } }.keyboardShortcut("]").disabled(!store.canGoForward)
            Divider()
            Button("Jump to Conversation…") { chat?.jump() }.keyboardShortcut("k").disabled(chat == nil)
            // ⌥⌘, not ⌥: ⌥↑/⌥↓ move by paragraph in every text field.
            Button("Next Unread") { chat?.unread(true) }.keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(chat == nil)
            Button("Previous Unread") { chat?.unread(false) }.keyboardShortcut(
                .upArrow, modifiers: [.option, .command]
            ).disabled(chat == nil)
        }
        ConversationMenu(store: store, chat: chat, openFocused: openFocused)
        FormatMenu(composer: ComposerFocus.shared.composer)
    }
}

/// Conversation: what the sidebar's menu does to a conversation, for the one on screen, as Mail's Mailbox and Message
/// menus act on what is open. Leave and Block ask first, in the window.
struct ConversationMenu: Commands {
    let store: ChatStore
    let chat: ChatCommands?
    var openFocused: FocusedOpen?  // what has the keyboard: rows selected in Home, Mentions or Starred, or the thread pane
    var body: some Commands {
        CommandMenu("Conversation") {
            let room = chat?.room
            Button(room.map { $0.unread > 0 } == true ? "Mark as Read" : "Mark as Unread") {
                guard let room else { return }
                Task { if room.unread > 0 { await store.markAsRead(room.id) } else { await store.markUnread(room.id) } }
            }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(room == nil)
            Button("Mark All as Read") { Task { await store.markAllRead() } }
                .keyboardShortcut("u", modifiers: [.command, .shift, .option]).disabled(store.unreadCount == 0)
            Divider()
            Button(room?.pinned == true ? "Unpin" : "Pin") {
                if let room { Task { await store.setSidebarPinned(!room.pinned, room.id) } }
            }.disabled(room == nil)
            Button(room?.muted == true ? "Unmute" : "Mute") {
                if let room { Task { await store.setMuted(!room.muted, room.id) } }
            }.disabled(room == nil)
            if let room {
                NotificationLevelPicker(room: room).environment(store)
            } else {
                Menu("Notifications") {}.disabled(true)
            }
            Divider()
            Button(chat?.threadsShown == true ? "Hide Threads" : "Show Threads") { chat?.threads?() }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(chat?.threads == nil)
            let open = openFocused?.open ?? chat?.openInWindow
            Button(openFocused?.title ?? "Open in New Window") { open?() }.keyboardShortcut("o").disabled(open == nil)
            Button("Copy Link") { if let room { ChatLink.copy(ChatLink.url(room.id)) } }.disabled(room == nil)
            Divider()
            MoveToMenu(room: room) { chat?.newSection?() }.environment(store).disabled(
                room == nil || room?.app == .gemini)
            Button("Hide") { if let room { Task { await store.hide(room.id) } } }.disabled(room == nil)
            Button("Leave…") { chat?.leave?() }.disabled(chat?.leave == nil)
            Button("Block…") { chat?.block?() }.disabled(chat?.block == nil)
        }
    }
}

/// Format: the composer's formatting, as Mail's Format menu, with the keys the composer already takes. Off unless a
/// composer is being typed in.
struct FormatMenu: Commands {
    let composer: ComposerTextView?
    var body: some Commands {
        CommandMenu("Format") {
            Group {
                Button("Bold") { composer?.formatBold(nil) }.keyboardShortcut("b")
                Button("Italic") { composer?.formatItalic(nil) }.keyboardShortcut("i")
                Button("Underline") { composer?.formatUnderline(nil) }.keyboardShortcut("u")
                Button("Strikethrough") { composer?.formatStrike(nil) }.keyboardShortcut(
                    "x", modifiers: [.command, .shift])
                Menu("Text Color") {
                    Button("Default") { composer?.color(nil) }
                    ForEach(TextColor.allCases, id: \.self) { color in Button(color.name) { composer?.color(color) } }
                }
                Divider()
                Button("Bulleted List") { composer?.formatList(nil) }.keyboardShortcut(
                    "8", modifiers: [.command, .shift])
                Button("Quote") { composer?.formatQuote(nil) }.keyboardShortcut("'")
                Button("Link…") { composer?.formatLink(nil) }.keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Code") { composer?.formatCode(nil) }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Code Block") { composer?.formatCodeBlock(nil) }.keyboardShortcut(
                    "c", modifiers: [.command, .shift, .option])
                Divider()
                Button("Clear Formatting") { composer?.formatClear(nil) }
            }.disabled(composer == nil)
        }
    }
}

/// Help ▸ Report a Problem…: the diagnostics window, whose Save Log… makes the file to send.
struct DiagnosticsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Report a Problem…") { openWindow(id: "connection-diagnostics") }
    }
}

/// File ▸ Send a Meet Link (⇧⌘M), for the conversation in the focused window.
struct MeetLinkMenuItem: View {
    @Environment(ChatStore.self) private var store
    @FocusedValue(\.meetLinkConversation) private var conversation
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button("Send a Meet Link") {
            guard let conversation else { return }
            Task { if let url = await store.sendMeetLink(in: conversation) { openURL(url) } }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(conversation == nil)
    }
}
