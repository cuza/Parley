import ParleyDomain
import SwiftUI

/// The window's detail column: Home, a shortcut's list, Gemini, or a conversation with its side pane and its
/// customizable toolbar.
extension ChatView {
    /// Posts a new Meet meeting in the conversation and opens it, as Google Chat's "Send a Meet link" does.
    private func sendMeetLink(_ id: ConversationID) {
        Task { if let url = await store.sendMeetLink(in: id) { openURL(url) } }
    }
    @ViewBuilder var detail: some View {
        if fixedConversation == nil, store.navigation.shortcut == .home {
            HomePane().safeAreaInset(edge: .top, spacing: 0) { expiredBanner }.toolbar { searchItem }
        } else if fixedConversation == nil, store.navigation.shortcut == .drafts {
            DraftList().safeAreaInset(edge: .top, spacing: 0) { expiredBanner }.toolbar { searchItem }
        } else if fixedConversation == nil, let shortcut = store.navigation.shortcut {
            ShortcutList(shortcut: shortcut).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }.toolbar {
                searchItem
            }
        } else if let room, room.app == .gemini {
            GeminiPane(room: room).id(room.id).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
        } else if let room {
            // Scroll state belongs to one conversation; the toolbar stays outside so it is not duplicated on switch.
            // The thread and info panel is our own pane: SwiftUI's .inspector inside a NavigationSplitView
            // re-measures its columns without settling on macOS 27 and AppKit aborts the app.
            SidePaneSplit(open: paneOpen) {
                VStack(spacing: 0) { TimelineView(conversation: room).id(room.id) }
                    .safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
            } pane: {
                Group {
                    if let person = pane.person {
                        PersonDetailsPane(person: person).id(person.id)
                    } else if pane.info {
                        InfoPanel(room: room, search: fixedConversation == nil ? { finding = .init(scope: room) } : nil)
                    } else if let thread = pane.thread {
                        ThreadPane(room: room, thread: thread)
                    } else if pane.threads, Self.offersThreads(room) {
                        ThreadsPane(room: room)
                    }
                }
                // Esc closes the info panel wherever focus is; the composer's own Esc also closes it. While the composer
                // quotes or edits, Esc is the composer's, to drop the quote or end the edit first.
                .hiddenShortcut(
                    .cancelAction, enabled: pane.info && !ComposerBar.ownsEsc(store, store.key(room.id, nil))
                ) {
                    store.navigation.setPane(fixedConversation) { $0.closeInfo() }
                }
            }
            // Customizable, as Mail's: View ▸ Customize Toolbar… or a right-click adds Info and Attach, removes items,
            // and shows their names (Icon and Text). The title stays put.
            .toolbar(id: "conversation") {
                // On the left in the title's place and size, as Home and the other shortcuts show theirs.
                ToolbarItem(id: "title", placement: .navigation) {
                    // As Google Chat's header and the sidebar show it: the space's emoji or image, or the person's
                    // photo with their presence on its corner, then the name.
                    Button {
                        store.toggleInfo(window: fixedConversation)
                    } label: {
                        HStack(spacing: 8) {
                            Avatar(room: room, size: 24)
                                .overlay(alignment: .bottomTrailing) {
                                    if let partner = store.partner(in: room) {
                                        PresenceDot(presence: store.presence.availability[partner], size: 8).offset(
                                            x: 2, y: 2)
                                    }
                                }
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(room.name).font(.title3.weight(.semibold)).lineLimit(1)
                                    if room.external == true { ExternalBadge() }
                                }
                                if room.kind != .direct, !room.members.isEmpty {
                                    Text("\(room.members.count) members").font(.caption).foregroundStyle(.secondary)
                                }
                                if let partner = store.partner(in: room),
                                    let status = store.presence.customStatus[partner]
                                {
                                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Conversation info (⇧⌘I)")
                }
                .customizationBehavior(.disabled)
                .titleWithoutGlass()
                if #available(macOS 26, *) { ToolbarSpacer(.flexible) }  // search on the right, the name on the left
                // Web's call button; a menu, as calls and huddles may join it.
                ToolbarItem(id: "call", placement: .primaryAction) {
                    Menu {
                        Button("Send a Meet Link") { sendMeetLink(room.id) }
                    } label: {
                        Label("Video Call", systemImage: "video")
                    }
                    .menuIndicator(.visible).help("Video call")
                }
                if Self.offersThreads(room) {  // the conversation's threads, as Google Chat's Active threads
                    ToolbarItem(id: "threads", placement: .primaryAction) {
                        Button {
                            Task { await store.toggleThreads(window: fixedConversation) }
                        } label: {
                            Label("Threads", systemImage: "bubble.left.and.text.bubble.right")
                        }
                        .help("Threads")
                    }
                }
                ToolbarItem(id: "info", placement: .primaryAction, showsByDefault: false) {
                    Button {
                        store.toggleInfo(window: fixedConversation)
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }.help("Conversation info (⇧⌘I)")
                }
                ToolbarItem(id: "attach", placement: .primaryAction, showsByDefault: false) {
                    Button {
                        commands.attach?()
                    } label: {
                        Label("Attach", systemImage: "paperclip")
                    }.help("Attach files (⇧⌘A)")
                }
                if fixedConversation == nil {  // results open in the main window, so search lives only there
                    ToolbarItem(id: "search", placement: .primaryAction) {
                        Button {
                            find()
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }.help("Search messages (⌘F)")
                    }
                }
            }
            .focusedSceneValue(\.meetLinkConversation, room.id)
            .toolbar(removing: .title)  // the conversation's name is the title; the window keeps "Parley" for its menus
            .safeAreaInset(edge: .top, spacing: 0) { Divider() }  // the line under the header, as Home's
        } else {
            ContentUnavailableView(
                "Choose a conversation", systemImage: "bubble.left.and.bubble.right",
                description: Text("Select one in the sidebar, or press ⌘K to jump to one.")
            )
            .safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
        }
    }
    /// Search, on the right of the toolbar: conversations and the shortcuts alike, as ⌘F works in both.
    private var searchItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                find()
            } label: {
                Label("Search", systemImage: "magnifyingglass").labelStyle(.iconOnly)
            }.help("Search messages (⌘F)")
        }
    }
    /// Over the detail: the expired session's banner, else the offline banner.
    @ViewBuilder private var expiredBanner: some View {
        if store.sessionExpired, let signIn {
            SessionExpiredBanner(flow: signIn)
        } else {
            OfflineBanner(connection: store.connection)
        }
    }
}
