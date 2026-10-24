import ParleyDomain
import SwiftUI

/// The main window's sidebar: the search and New Chat buttons, Shortcuts, then the conversations by section, and my
/// status at the foot.
extension ChatView {
    /// Limit sidebar sections' count, nil when off, and the sections the user expanded with Show all (stored by title).
    var sectionLimitArgs: (limit: Int?, expanded: Set<SidebarKey>) {
        (
            limitSections ? sectionLimit : nil,
            Set(expandedSections.split(separator: "\n").compactMap { SidebarKey(title: String($0)) })
        )
    }
    /// `titles` (one per line) with `title` added or removed.
    private static func lines(_ titles: String, _ title: String, contains: Bool) -> String {
        var set = Set(titles.split(separator: "\n").map(String.init))
        if contains { set.insert(title) } else { set.remove(title) }
        return set.sorted().joined(separator: "\n")
    }
    @ViewBuilder var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    switcher = true
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Jump to conversation")
                        Spacer()
                        Text("⌘K").font(.caption)
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Button {
                    composing = true
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14))
                }
                .buttonStyle(.borderless).help("New Chat (⌘N)").accessibilityLabel("New Chat")
            }.padding(14)
            // A row's tag is a shortcut's or a conversation's id, so the selection is plain text.
            List(
                selection: Binding(
                    get: {
                        fixedConversation?.rawValue ?? store.navigation.shortcut.map(Self.tag)
                            ?? store.navigation.selectedID?.rawValue
                    },
                    set: { tag in
                        guard let tag else { return }
                        if let shortcut = Shortcut.allCases.first(where: { Self.tag($0) == tag }) {
                            Task { await store.openShortcut(shortcut) }
                        } else if let id = store.rooms.conversations.first(where: { $0.id.rawValue == tag })?.id {  // not a "Show all" row
                            Task { await store.select(id) }
                        }
                    })
            ) {
                ForEach(
                    Conversation.sidebarSections(
                        store.rooms.conversations, limit: sectionLimitArgs.limit, expanded: sectionLimitArgs.expanded,
                        selected: fixedConversation ?? store.navigation.selectedID, custom: store.rooms.sections),
                    id: \.key
                ) {
                    section($0.key, title: $0.title, rooms: $0.rooms, hidden: $0.hidden)
                }
            }.listStyle(.sidebar).accessibilityIdentifier("sidebar")
            OwnStatusFooter()
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            if $0 > 0 { sidebarWidth = $0 }
        }
        .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: 230, max: Self.sidebarMaxWidth)
    }
    /// A shortcut's sidebar row tag; conversation ids never start with it.
    private static func tag(_ shortcut: Shortcut) -> String { "shortcut:" + shortcut.rawValue }
    /// A sidebar row as VoiceOver reads it: the name, then unread, pinned and muted when they are so.
    static func spoken(_ room: Conversation) -> String {
        ([room.name]
            + [
                room.unread > 0 ? "\(room.unread) unread" : nil, room.unreadThreads.map { "\($0) unread threads" },
                room.pinned ? "pinned" : nil, room.muted ? "muted" : nil,
            ].compactMap { $0 })
            .joined(separator: ", ")
    }
    /// One of my own sections, by its key.
    private func customSection(_ key: SidebarKey) -> SidebarSection? {
        guard case .custom(let id) = key else { return nil }
        return store.rooms.sections.first { $0.kind == .custom && $0.key == id }
    }
    /// A collapsible section; which ones are collapsed is remembered across launches. Shortcuts lists Home, Mentions,
    /// Starred and Drafts.
    /// Collapsed, its header counts its unread messages, as web Chat. `hidden`: rows Limit sidebar sections leaves out.
    @ViewBuilder private func section(_ key: SidebarKey, title: String, rooms: [Conversation], hidden: [Conversation])
        -> some View
    {
        // My own sections show even when empty, as Google Chat's do, with how to fill them.
        if !rooms.isEmpty || (key == .shortcuts && fixedConversation == nil)
            || (customSection(key) != nil && fixedConversation == nil)
        {
            let collapsed = collapsedSections.split(separator: "\n").contains { $0 == title }
            Section(
                isExpanded: Binding(
                    get: { !collapsed },
                    set: { collapsedSections = Self.lines(collapsedSections, title, contains: !$0) })
            ) {
                if key == .shortcuts && fixedConversation == nil {
                    shortcutRows
                }
                ForEach(rooms) { room in
                    roomRow(room)
                }
                if rooms.isEmpty, customSection(key) != nil {
                    Text("Right-click a conversation and choose Move To.").font(.caption).foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                if !hidden.isEmpty {
                    let open = sectionLimitArgs.expanded.contains(key)
                    Button {
                        expandedSections = Self.lines(expandedSections, title, contains: !open)
                    } label: {
                        HStack(spacing: 8) {  // laid out as a room row, so the icon and text line up with the avatars and names
                            ShowAllIcon(open: open).frame(width: 20, height: 20)
                            Text(open ? "Show less" : "Show all").foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).selectionDisabled()  // a click on the row toggles it, never selects it
                }
                if key == .spaces, case let count = store.rooms.invitations.count, count > 0 {
                    // Google Chat keeps invitations in its space browser; this row is the way to notice one. It opens Browse spaces.
                    Button {
                        store.newChatRequests += 1
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.badge").foregroundStyle(Color.accentColor).frame(
                                width: 20, height: 20)
                            Text(Self.invitationsTitle(count))
                        }
                    }.buttonStyle(.plain).selectionDisabled()
                }
            } header: {
                sectionHeader(key, title: title, rooms: rooms, collapsed: collapsed)
            }
        }
    }
    /// Home, Mentions, Starred and Drafts, with Home's unread threads and Drafts' count.
    private var shortcutRows: some View {
        ForEach(Shortcut.allCases, id: \.self) { shortcut in
            HStack {
                Label(shortcut.title, systemImage: shortcut.icon)
                if shortcut == .home, case let count = store.unreadThreadCount, count > 0 {  // threads with new replies, which the Dock badge counts too
                    Spacer(minLength: 0)
                    UnreadPill(count: count).accessibilityLabel("\(count) unread threads")
                }
                if shortcut == .drafts, case let count = store.draftCount + store.drafting.scheduled.count,
                    count > 0
                {  // as web shows it
                    Spacer(minLength: 0)
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityLabel(
                        "\(count) drafts")
                }
            }.tag(Self.tag(shortcut))
        }
    }
    /// A conversation's row: its picture (with the partner's presence), name, muted bell and unread count, and its
    /// context menu.
    private func roomRow(_ room: Conversation) -> some View {
        HStack(spacing: 8) {
            Avatar(room: room, size: 20)
                .overlay(alignment: .bottomTrailing) {
                    if let partner = store.partner(in: room) {
                        PresenceDot(presence: store.presence.availability[partner], size: 7).offset(
                            x: 2, y: 2)
                    }
                }
            Text(room.name).fontWeight(
                room.unread > 0 || (room.unreadThreads ?? 0) > 0 ? .semibold : .regular
            ).lineLimit(1).truncationMode(.tail).help(room.name)
            Spacer(minLength: 0)
            if room.muted { Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.secondary) }
            if room.unread > 0 { UnreadPill(count: room.unread) }
        }.tag(room.id.rawValue)
            // A double-click opens it in a window of its own, as in Messages; ⌘-click too, as Safari's new tab
            // (conversation windows join as tabs). The sidebar selects one row at a time, so ⌘-click is free.
            .simultaneousGesture(TapGesture(count: 2).onEnded { openWindow(value: room.id) })
            .highPriorityGesture(TapGesture().modifiers(.command).onEnded { openWindow(value: room.id) })
            .contextMenu {
                if room.unread > 0 {
                    Button("Mark as Read") { Task { await store.markAsRead(room.id) } }
                } else {
                    Button("Mark as Unread") { Task { await store.markUnread(room.id) } }
                }
                Button(room.pinned ? "Unpin" : "Pin") {
                    Task { await store.setSidebarPinned(!room.pinned, room.id) }
                }
                Button(room.muted ? "Unmute" : "Mute") {
                    Task { await store.setMuted(!room.muted, room.id) }
                }
                NotificationLevelPicker(room: room)
                Button("Open in New Window") { openWindow(value: room.id) }
                Button("Copy Link") { ChatLink.copy(ChatLink.url(room.id)) }
                Button("Hide") { Task { await store.hide(room.id) } }
                if room.app != .gemini {
                    MoveToMenu(room: room) {
                        sectionName = ""
                        naming = SectionNaming(moving: room.id)
                    }
                }
                if room.kind != .direct {
                    Divider()
                    Button("Leave…", role: .destructive) { leaving = room }
                }
                if room.kind == .space {
                    Button("Block…", role: .destructive) { blocking = .space(room.id, name: room.name) }
                } else if room.kind == .direct, room.app == nil, let partner = store.partner(in: room) {
                    Divider()
                    Button("Block…", role: .destructive) { blocking = .person(partner, name: room.name) }
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(Self.spoken(room))
            .draggable(ChatLink.url(room.id))  // to Safari, Notes or Finder, as its Google Chat link
    }
    /// A section's title, with my own sections' menu; collapsed, the unread messages it holds.
    private func sectionHeader(_ key: SidebarKey, title: String, rooms: [Conversation], collapsed: Bool) -> some View {
        HStack {
            Text(title)
                .contextMenu {
                    if let mine = customSection(key) {
                        Button("Rename Section…") {
                            sectionName = mine.name
                            naming = SectionNaming(section: mine)
                        }
                        Button("Move Section Up") { Task { await store.moveSection(mine, up: true) } }
                        Button("Move Section Down") { Task { await store.moveSection(mine, up: false) } }
                        Divider()
                        Button("Delete Section…", role: .destructive) { deletingSection = mine }
                    }
                }
            if collapsed, case let unread = rooms.filter { !$0.muted }.reduce(0, { $0 + $1.unread }), unread > 0 {
                Spacer(minLength: 0)
                Text("\(unread)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(
                    .secondary
                )
                .accessibilityLabel("\(unread) unread")
            }
        }
    }
    /// The Spaces section's row for space invitations.
    static func invitationsTitle(_ count: Int) -> String {
        count == 1 ? "1 space invitation" : "\(count) space invitations"
    }
}

/// The sidebar's Show all / Show less icon, as web Chat draws it: chevrons pointing apart to show more, together to show
/// less. SF Symbols has only the first, so the second is two chevrons stacked.
struct ShowAllIcon: View {
    let open: Bool
    var body: some View {
        if open {
            VStack(spacing: -3) {
                Image(systemName: "chevron.down")
                Image(systemName: "chevron.up")
            }
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        } else {
            Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
        }
    }
}

/// Move To: one of my sections, a new one, or back to its default section, as Google Chat's Move conversation. The
/// sidebar's context menu and the Conversation menu both show it.
struct MoveToMenu: View {
    @Environment(ChatStore.self) private var store
    let room: Conversation?
    let newSection: () -> Void
    var body: some View {
        Menu("Move To") {
            if let room {
                if room.section != nil {
                    Button(room.kind == .space ? "Spaces" : room.app != nil ? "Apps" : "Direct messages") {
                        Task { await store.moveConversation(room.id, to: nil) }
                    }
                }
                ForEach(store.rooms.sections.filter { $0.kind == .custom && $0.key != room.section }) { section in
                    Button(section.name) { Task { await store.moveConversation(room.id, to: section.key) } }
                }
                Divider()
                Button("New Section…", action: newSection)
            }
        }
    }
}
