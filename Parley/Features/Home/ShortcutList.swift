import ParleyDomain
import SwiftUI

/// Home: conversations by recent activity, a click opens one. Mentions or Starred: messages from every conversation,
/// newest first; a click opens the message where it is.
struct ShortcutList: View {
    @Environment(ChatStore.self) private var store
    let shortcut: Shortcut
    /// Rows chosen with the arrow keys, ⌘-click or ⇧-click, as in Mail's message list. Return or a double-click opens
    /// one, and the context menu acts on all of them.
    @State private var selection = Set<String>()  // Home rows' ids or messages' ids, so plain text
    /// Choosing rows takes the keyboard from the sidebar, so the arrow keys and Return then act on the list.
    @FocusState private var listFocused: Bool
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        @Bindable var store = store
        // Home reads its rows, not the shortcut's messages (a scan of every message on each update).
        let items = shortcut == .home ? [] : store.shortcutMessages(shortcut)
        Group {
            if shortcut == .home {
                let rows = store.homeRows(unreadOnly: store.homeUnreadOnly, threadsOnly: store.homeThreadsOnly)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {  // web's "Unread" switch and "Thread" filter
                        Toggle("Unread", isOn: $store.homeUnreadOnly).toggleStyle(.switch).controlSize(.mini)
                        Toggle(isOn: $store.homeThreadsOnly) {
                            Label("Threads", systemImage: "bubble.left.and.text.bubble.right")
                        }.toggleStyle(.button).controlSize(.small)
                        Spacer()
                    }
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 6)
                    if rows.isEmpty {
                        let filtered = store.homeUnreadOnly || store.homeThreadsOnly
                        ContentUnavailableView {
                            Label(filtered ? "Nothing here" : "No recent conversations", systemImage: shortcut.icon)
                        } description: {
                            Text(
                                filtered
                                    ? "No rows match these filters." : "Conversations with new messages show up here.")
                        } actions: {
                            if filtered {
                                Button("Show All") {
                                    store.homeUnreadOnly = false
                                    store.homeThreadsOnly = false
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)  // fills the pane, so the filter bar stays at the top
                    } else {
                        List(rows, selection: $selection) { row in
                            Group {
                                if let thread = row.thread {
                                    threadRow(row.room, thread)
                                        .listRowBackground(
                                            store.navigation.threadID == thread.id && !selection.contains(row.id)
                                                ? Color.accentColor.opacity(0.15) : nil)
                                } else {
                                    homeRow(row.room, row.last, me: store.me.id)
                                        .task(id: store.me.id) { await store.loadPreview(row.room.id) }  // again once the account is known
                                }
                            }
                            .accessibilityAction { open(row) }
                            .swipeActions(edge: .leading) { readSwipe(row) }
                            .swipeActions(edge: .trailing) { actionSwipe(row) }
                        }
                        .contextMenu(forSelectionType: String.self) { ids in
                            let chosen = rows.filter { ids.contains($0.id) }
                            let unread = chosen.filter { $0.thread == nil && $0.room.unread > 0 }
                            let threads = chosen.compactMap(\.thread)
                            if !chosen.isEmpty {
                                Button("Open in New Window") { openInWindows(chosen) }
                                Divider()
                            }
                            if !unread.isEmpty {
                                Button("Mark as Read") {
                                    Task { for row in unread { await store.markAsRead(row.room.id) } }
                                }
                            }
                            if !threads.isEmpty {
                                Button(threads.count == 1 ? "Unfollow Thread" : "Unfollow Threads") {
                                    Task { for thread in threads { await store.setFollowing(false, for: thread.id) } }
                                }
                            }
                        } primaryAction: { ids in
                            if let row = rows.first(where: { ids.contains($0.id) }) { open(row) }
                        }
                        .focusedValue(
                            \.openFocusedInWindow,
                            selection.isEmpty
                                ? nil : FocusedOpen { openInWindows(rows.filter { selection.contains($0.id) }) }
                        )
                        .focused($listFocused)
                        .background(FreeKeyboardWatcher { listFocused = true })
                        .onChange(of: selection) {
                            if !selection.isEmpty { listFocused = true }
                            if Self.clicked(selection), let row = rows.first(where: { selection.contains($0.id) }) {
                                open(row)
                            }
                        }
                        .accessibilityIdentifier("shortcut-home")
                    }
                }
            } else if !items.isEmpty {
                List(items, id: \.id.rawValue, selection: $selection) { message in
                    row(message)
                        // Starred: a full swipe unstars, and the row leaves the list, as Mail's archive.
                        .swipeActions(edge: .trailing, allowsFullSwipe: shortcut == .starred) {
                            Button {
                                Task { await store.setStarred(!message.starred, message) }
                            } label: {
                                Label(
                                    message.starred ? "Unstar" : "Star",
                                    systemImage: message.starred ? "star.slash" : "star")
                            }.tint(.yellow)
                        }
                        .accessibilityAction { Task { await store.showInChat(message) } }
                        .onAppear {
                            if message.id == items.last?.id { Task { await store.loadShortcut(shortcut, more: true) } }
                        }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let chosen = items.filter { ids.contains($0.id.rawValue) }
                    let starred = chosen.allSatisfy(\.starred)
                    if !chosen.isEmpty {
                        Button("Open in New Window") { openInWindows(chosen) }
                        Divider()
                    }
                    if !chosen.isEmpty {
                        Button(starred ? "Unstar" : "Star") {
                            Task { for message in chosen { await store.setStarred(!starred, message) } }
                        }
                    }
                } primaryAction: { ids in
                    if let message = items.first(where: { ids.contains($0.id.rawValue) }) {
                        Task { await store.showInChat(message) }
                    }
                }
                .focusedValue(
                    \.openFocusedInWindow,
                    selection.isEmpty
                        ? nil : FocusedOpen { openInWindows(items.filter { selection.contains($0.id.rawValue) }) }
                )
                .focused($listFocused)
                .background(FreeKeyboardWatcher { listFocused = true })
                .onChange(of: selection) {
                    if !selection.isEmpty { listFocused = true }
                    if Self.clicked(selection), let message = items.first(where: { selection.contains($0.id.rawValue) })
                    {
                        Task { await store.showInChat(message) }
                    }
                }
                .onCopyCommand {
                    items.filter { selection.contains($0.id.rawValue) }.map {
                        NSItemProvider(object: TextStyleRange.plain($0.text, $0.formatting) as NSString)
                    }
                }
                .accessibilityIdentifier("shortcut-\(shortcut.rawValue)")
            } else if store.history.loading.contains("shortcut/\(shortcut.rawValue)") {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    shortcut == .starred ? "No starred messages" : "No mentions", systemImage: shortcut.icon,
                    description: Text(
                        shortcut == .starred
                            ? "Star a message to find it here." : "Messages that @mention you show up here."))
            }
        }
        .navigationTitle(shortcut.title)
    }
    /// Open in New Window: each conversation in a window of its own (they join as tabs), a thread row in a thread window.
    private func openInWindows(_ rows: [HomeRow]) {
        for row in rows {
            if let thread = row.thread {
                openWindow(value: ThreadRef(conversation: row.room.id, thread: thread.id))
            } else {
                openWindow(value: row.room.id)
            }
        }
    }
    /// A Mention or Starred message's conversation, each once.
    private func openInWindows(_ messages: [Message]) {
        var seen = Set<ConversationID>()
        for id in messages.map(\.conversationID) where seen.insert(id).inserted { openWindow(value: id) }
    }
    /// Swiping right, as in Mail: read or unread. A thread row has no read state of its own to set.
    @ViewBuilder private func readSwipe(_ row: HomeRow) -> some View {
        if row.thread == nil {
            let unread = row.room.unread > 0
            Button {
                Task { if unread { await store.markAsRead(row.room.id) } else { await store.markUnread(row.room.id) } }
            } label: {
                Label(
                    unread ? "Mark as Read" : "Mark as Unread",
                    systemImage: unread ? "checkmark.message" : "message.badge")  // a chat bubble, not Mail's envelope
            }.tint(.blue)
        }
    }
    /// Swiping left: mute a conversation, or unfollow a thread.
    @ViewBuilder private func actionSwipe(_ row: HomeRow) -> some View {
        if let thread = row.thread {
            Button {
                Task { await store.setFollowing(false, for: thread.id) }
            } label: {
                Label("Unfollow", systemImage: "bell.slash")
            }.tint(.orange)
        } else {
            Button {
                Task { await store.setMuted(!row.room.muted, row.room.id) }
            } label: {
                Label(row.room.muted ? "Unmute" : "Mute", systemImage: row.room.muted ? "bell" : "bell.slash")
            }.tint(.indigo)
        }
    }
    /// A Home row opens its conversation, or its thread beside Home.
    private func open(_ row: HomeRow) {
        Task {
            if let thread = row.thread { await store.openHomeThread(thread) } else { await store.select(row.room.id) }
        }
    }
    /// Nothing has the keyboard: the window itself is first responder, and keys would beep.
    static func keyboardIsFree(_ window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard let window else { return true }
        return window.firstResponder == nil || window.firstResponder === window
    }
    /// A plain click still opens a row, as before these lists had a selection; the arrow keys and ⌘- or ⇧-click only
    /// select.
    static func clicked(_ selection: Set<String>, event: NSEvent? = NSApp.currentEvent) -> Bool {
        guard selection.count == 1, let event, event.type == .leftMouseDown || event.type == .leftMouseUp else {
            return false
        }
        return event.modifierFlags.isDisjoint(with: [.command, .shift])
    }
    /// Name and newest message, as "You: …" or "Sender: …", beside a column of time over unread count. The text ends
    /// `columnGap` before that column, which keeps its own trailing edge.
    func homeRow(_ room: Conversation, _ last: Message?, me: PersonID) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(room: room, size: 32)
            HStack(alignment: .top, spacing: Self.columnGap) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(room.name).font(.body.weight(room.unread > 0 ? .semibold : .regular)).lineLimit(1)
                        if room.muted { Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }
                    Group {
                        if let last { line(last, me: me) } else { Text(" ") }
                    }
                    .font(.body.weight(room.unread > 0 ? .medium : .regular)).lineLimit(2).frame(
                        maxWidth: .infinity, alignment: .leading
                    )
                    .reportFrame("preview")
                }
                VStack(alignment: .trailing, spacing: 3) {
                    if let time = last?.createdAt ?? room.activity {
                        Text(Self.time(time)).font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    if room.unread > 0 { UnreadPill(count: room.unread) }
                }
                .reportFrame("column")
            }
        }
        .coordinateSpace(name: "homeRow")
        .padding(.vertical, 4).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    /// The space between a Home row's text and its time and unread column.
    static let columnGap: CGFloat = 12
    /// "You: " or "Sender: " before a message's summary.
    private func line(_ message: Message, me: PersonID) -> Text {
        Text(message.sender.id == me ? "You: " : "\(message.sender.name): ").foregroundStyle(.secondary)
            + Text(
                Self.oneLine(
                    QuotedMessage.summary(
                        text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments))
            )
    }
    /// As web's thread row: the conversation and time, the thread's first message, then "└ newest reply"; bold with a dot when unread.
    private func threadRow(_ room: Conversation, _ thread: HomeThread) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(room: room, size: 32)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 8)).foregroundStyle(
                        .secondary
                    )
                    .padding(2).background(.background, in: Circle()).offset(x: 4, y: 4)
                }
            HStack(alignment: .top, spacing: Self.columnGap) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(room.name).font(.body.weight(thread.unread ? .semibold : .regular)).lineLimit(1)
                        Text("· Thread").font(.callout).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 0)
                    }
                    line(thread.head, me: store.me.id).font(.body).lineLimit(1).frame(
                        maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("└").foregroundStyle(.tertiary).accessibilityHidden(true)
                        line(thread.latest, me: store.me.id).font(.body.weight(thread.unread ? .medium : .regular))
                            .lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .trailing, spacing: 5) {  // the time over the unread dot, as a conversation's row has it
                    Text(Self.time(thread.time)).font(.caption).foregroundStyle(.secondary).fixedSize()
                    if thread.unread {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8).accessibilityLabel("Unread")
                    }
                }
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    /// As Google Chat's Home: the time within a day, then "Yesterday", the weekday within a week, the date this year,
    /// and the month and year before that.
    static func time(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String
    {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if now.timeIntervalSince(date) < 24 * 3600 { return date.formatted(style.hour().minute()) }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) {
            return String(localized: "Yesterday", locale: locale)
        }
        if now.timeIntervalSince(date) < 7 * 24 * 3600 { return date.formatted(style.weekday(.abbreviated)) }
        style =
            calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? style.month(.abbreviated).day() : style.month(.abbreviated).year()
        return date.formatted(style)
    }
    /// A preview on one paragraph: line breaks and runs of spaces become one space, as Google Chat's Home shows it.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func row(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.sender.name, size: 32, url: message.sender.avatarURL)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(message.sender.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(
                        "· \(store.rooms.conversations.first { $0.id == message.conversationID }?.name ?? "Conversation")"
                    )
                    .font(.body).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if message.starred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel(
                            "Starred")
                    }
                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        .foregroundStyle(.secondary).fixedSize()
                }
                Text(
                    QuotedMessage.summary(
                        text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments)
                )
                .font(.body).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
    }
}

/// Frames of a Home row's parts in its "homeRow" coordinate space, so a test can check the spacing.
struct RowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
extension View {
    func reportFrame(_ id: String) -> some View {
        background(
            GeometryReader { Color.clear.preference(key: RowFrames.self, value: [id: $0.frame(in: .named("homeRow"))]) }
        )
    }
}

/// Hands the keyboard to a list whenever its window's keyboard has nowhere to go: at launch, and when the composer that
/// had it leaves with its conversation, which can be a few run-loop turns after the list appears. A click in the sidebar
/// keeps the keyboard there, as in Mail; Tab moves on to the list.
struct FreeKeyboardWatcher: NSViewRepresentable {
    var free: () -> Void
    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) { view.free = free }
    final class Watcher: NSView {
        var free: (() -> Void)?
        private var watch: NSKeyValueObservation?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
                // Not inside the change: focus moves after it.
                DispatchQueue.main.async { if ShortcutList.keyboardIsFree(window) { self?.free?() } }
            }
        }
    }
}
