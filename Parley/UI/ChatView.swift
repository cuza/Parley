import AppIntents
import AppKit
import SwiftUI

/// A space's emoji, else its photo or image, else initials (people) or # (spaces). Circle for people, rounded square for spaces.
struct Avatar: View {
    let name: String
    var space = false
    var size: CGFloat = 24
    var url: URL? = nil
    var emoji: String? = nil
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale
    private var hue: Double { Self.hue(name) }
    nonisolated static func hue(_ name: String) -> Double { Double(name.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360 }
    nonisolated static func initials(_ name: String) -> String { name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined() }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: space ? size * 0.27 : size / 2) }
    var body: some View {
        ZStack {
            if let emoji {
                shape.fill(.quaternary)
                Text(emoji).font(.system(size: size * 0.62))
            } else if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                shape.fill(Color(hue: hue, saturation: 0.35, brightness: 0.55))   // white initials stay readable on it
                if space { Image(systemName: "number").font(.system(size: size * 0.52, weight: .medium)) }
                else { Text(Self.initials(name)).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)) }
            }
        }.foregroundStyle(.white).frame(width: size, height: size).clipShape(shape).accessibilityHidden(true)
            .task(id: emoji == nil ? url : nil) {
                image = nil
                if emoji == nil, let url, let loaded = await RemoteImage.image(url, px: Int((size * scale).rounded())), !Task.isCancelled {
                    image = loaded   // a cancelled load (the row was recycled) must not blank the newer avatar
                }
            }
    }
}
/// Green when active, a hollow ring when away, red when not to be disturbed; nothing while unknown.
struct PresenceDot: View {
    let presence: Presence?
    var size: CGFloat = 8
    var body: some View {
        switch presence {
        case .available: Circle().fill(.green).frame(width: size, height: size).overlay(Circle().stroke(.background, lineWidth: 1.5)).accessibilityLabel("Active")
        case .away: Circle().strokeBorder(.secondary, lineWidth: 1.5).background(Circle().fill(.background)).frame(width: size, height: size).accessibilityLabel("Away")
        case .doNotDisturb: Circle().fill(.red).frame(width: size, height: size).overlay(Circle().stroke(.background, lineWidth: 1.5)).accessibilityLabel("Do not disturb")
        case .offline, nil: EmptyView()
        }
    }
}
struct ChatView: View {
    @Bindable var store: ChatStore
    var fixedConversation: String? = nil
    init(store: ChatStore, fixedConversation: String? = nil) {
        _store = Bindable(store); self.fixedConversation = fixedConversation
        _columns = State(initialValue: Self.initialColumns(fixedConversation: fixedConversation))
    }
    /// A conversation in its own window opens without the sidebar: there is nothing to choose there.
    static func initialColumns(fixedConversation: String?) -> NavigationSplitViewVisibility { fixedConversation == nil ? .all : .detailOnly }
    @State private var switcher = false
    @State private var composing = false   // the palette as New Chat
    @State private var finding: FinderPanel.Request?
    @State private var creatingSpace = false
    @State private var columns: NavigationSplitViewVisibility
    @State private var sidebarAutoHidden = false   // hidden by us for a narrow window: it comes back when there is room
    @State private var width = WidthRef()   // read only by actions, so kept out of state: it changes every frame of a resize
    @State private var sidebarWidth: CGFloat = 230   // as last measured while shown
    @State private var hostWindow = WindowRef()   // this view's own window
    @State private var leaving: Conversation?   // asks before leaving
    @State private var blocking: BlockSheet.Target?
    @State private var deletingSection: SidebarSection?   // asks before deleting a section
    @State private var naming: SectionNaming?   // New Section (with the conversation that goes in it) or Rename
    @State private var sectionName = ""
    struct SectionNaming: Identifiable { var id: String { section?.id ?? "new-\(moving ?? "")" }; var section: SidebarSection?; var moving: ConversationID? }
    @AppStorage("collapsedSidebarSections") private var collapsedSections = ""   // titles, one per line
    @AppStorage(SidebarLimit.enabledKey) private var limitSections = false
    @AppStorage(SidebarLimit.countKey) private var sectionLimit = 10
    @AppStorage(SidebarLimit.expandedKey) private var expandedSections = ""   // "Show all" sections' titles, one per line
    private var sectionLimitArgs: (limit: Int?, expanded: Set<String>) {
        (limitSections ? sectionLimit : nil, Set(expandedSections.split(separator: "\n").map(String.init)))
    }
    /// `titles` (one per line) with `title` added or removed.
    private static func lines(_ titles: String, _ title: String, contains: Bool) -> String {
        var set = Set(titles.split(separator: "\n").map(String.init))
        if contains { set.insert(title) } else { set.remove(title) }
        return set.sorted().joined(separator: "\n")
    }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL
    /// Posts a new Meet meeting in the conversation and opens it, as Google Chat's "Send a Meet link" does.
    private func sendMeetLink(_ id: ConversationID) { Task { if let url = await store.sendMeetLink(in: id) { openURL(url) } } }
    @Environment(SignInFlow.self) private var signIn: SignInFlow?
    /// This window's side pane: a conversation window has its own, so a thread opened there stays there.
    private var pane: SidePane { store.pane(fixedConversation) }
    private var paneOpen: Bool { pane.info || pane.thread != nil }
    private var room: Conversation? { store.conversations.first { $0.id == (fixedConversation ?? store.selectedID) } }
    /// ⌘F: search what's open, the conversation as the "said in" filter, or everywhere from Home and the other shortcuts.
    private func find() { finding = .init(scope: store.shortcut == nil ? room : nil) }
    /// A conversation's own window: titled with its name, which its tab and the Window menu show, and tabbed with the
    /// conversation window already open.
    private func tabbed(_ window: NSWindow) { if fixedConversation != nil { ConversationTabs.join(window, among: NSApp.windows) } }
    private var windowTitle: String? { fixedConversation == nil ? nil : room?.name }
    /// ⌘F's panel, or Search Messages' from Shortcuts, which opens in the main window only.
    private var findingSheet: Binding<FinderPanel.Request?> {
        Binding(get: { finding ?? (fixedConversation == nil ? store.searchRequest.map { FinderPanel.Request(id: $0.id, scope: nil, query: $0.query) } : nil) },
                set: { finding = $0; if $0 == nil { store.searchRequest = nil } })
    }
    /// Send to Parley picks its conversation in the main window only.
    private var sharing: Binding<Shared?> {
        Binding(get: { fixedConversation == nil ? store.sharing : nil }, set: { store.sharing = $0 })
    }
    /// What this window's menu items do.
    private var commands: ChatCommands {
        ChatCommands(
            find: fixedConversation == nil ? { find() } : nil,
            jump: { switcher = true },
            info: { if room != nil { store.toggleInfo(window: fixedConversation) } },
            editLast: { if let room, let last = store.timeline(room.id).last(where: { $0.sender.id == store.me.id }) { store.edit(last) } },
            unread: { forward in
                if let room = Conversation.nextUnread(after: store.selectedID, in: store.conversations, forward: forward) { Task { await store.select(room.id) } }
            },
            room: shown,
            threads: shown.flatMap { Self.offersThreads($0) ? { Task { await store.toggleThreads(window: fixedConversation) } } : nil },
            threadsShown: pane.threads && pane.thread == nil,
            openInWindow: shown.flatMap { room in fixedConversation == nil ? { openWindow(value: room.id) } : nil },
            newSection: shown.map { room in { sectionName = ""; naming = SectionNaming(moving: room.id) } },
            leave: shown.flatMap { room in room.kind != .direct ? { leaving = room } : nil },
            block: shown.flatMap { room in
                if room.kind == .space { return { blocking = .space(room.id, name: room.name) } }
                guard room.kind == .direct, room.app == nil, let partner = store.partner(in: room) else { return nil }
                return { blocking = .person(partner, name: room.name) }
            },
            attach: shown.map { room in { Self.chooseFiles { urls in
                // Into the composer being typed in (a thread's, say), else the conversation's own.
                if let composer = ComposerFocus.shared.composer, let attach = composer.attach { attach(urls) }
                else { store.attach(urls, conversation: room.id, thread: nil) }
            } } })
    }
    /// The conversation on screen, for the menus: none while Home or another shortcut is.
    private var shown: Conversation? { fixedConversation != nil || store.shortcut == nil ? room : nil }
    /// File ▸ Attach Files… and the paperclip: the open panel, as Mail's.
    static func chooseFiles(_ chosen: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.begin { response in if response == .OK { chosen(panel.urls) } }
    }
    private var handoff: URL? { Self.handoffURL(room, shortcut: fixedConversation == nil ? store.shortcut : nil) }
    /// What Handoff offers: the conversation on screen; Home and the other shortcuts have no web page of their own.
    static func handoffURL(_ room: Conversation?, shortcut: Shortcut?) -> URL? {
        guard shortcut == nil, let room else { return nil }
        return ChatLink.url(room.id)
    }
    /// `paneWidth` is the side pane's narrowest (and first) width; dragging its divider widens it up to `paneMaxWidth`.
    /// The sidebar's bounds take effect only as the column's outermost modifier: under another, the split view ignores them.
    static let paneWidth: CGFloat = 340, paneMaxWidth: CGFloat = 560, timelineMinWidth: CGFloat = 380, sidebarMinWidth: CGFloat = 180, sidebarMaxWidth: CGFloat = 300
    /// What the shown areas need: the sidebar at its width (0 when hidden), the timeline's minimum and, while open, the
    /// side pane. The split view keeps the sidebar's width as the window narrows and would clip the rest.
    static func minWidth(paneOpen: Bool, sidebar: CGFloat) -> CGFloat {
        sidebar + timelineMinWidth + (paneOpen ? 1 + paneWidth : 0)
    }
    /// As Mail does: a window too narrow for the sidebar hides it, and gives it back once it is wide enough again,
    /// unless the user hid it themselves.
    static func sidebar(width: CGFloat, paneOpen: Bool, sidebarWidth: CGFloat, visible: Bool, autoHidden: Bool) -> (visible: Bool, autoHidden: Bool) {
        let fits = width >= minWidth(paneOpen: paneOpen, sidebar: sidebarWidth)
        if visible, !fits { return (false, true) }
        if !visible, autoHidden, fits { return (true, false) }
        return (visible, autoHidden && !visible)
    }
    /// The sidebar's width as the window's needs count it: none in a conversation's own window or while hidden.
    static func shownSidebar(fixedConversation: String?, columns: NavigationSplitViewVisibility, measured: CGFloat) -> CGFloat {
        fixedConversation != nil || columns == .detailOnly ? 0 : measured
    }
    /// The window's width once a pane opens: grown only by what the shown areas lack.
    static func widthForPane(window: CGFloat, sidebar: CGFloat) -> CGFloat { max(window, minWidth(paneOpen: true, sidebar: sidebar)) }
    /// Widens the window to `wanted` (within the screen), if it is narrower.
    /// Only `window`, the view's own: every window shares the store, so each sees a pane open and must not resize another.
    static func makeRoom(_ wanted: CGFloat, in window: NSWindow?, animate: Bool = true) {
        guard let window, window.frame.width < wanted else { return }
        var frame = window.frame
        frame.size.width = min(wanted, window.screen?.visibleFrame.width ?? wanted)
        if let screen = window.screen?.visibleFrame { frame.origin.x = min(frame.origin.x, screen.maxX - frame.width) }
        window.setFrame(frame, display: true, animate: animate)
    }
    private func fitSidebar() {
        let next = Self.sidebar(width: width.value, paneOpen: paneOpen, sidebarWidth: sidebarWidth,
                                visible: columns != .detailOnly, autoHidden: sidebarAutoHidden)
        if (columns != .detailOnly) != next.visible { columns = next.visible ? .all : .detailOnly }
        if sidebarAutoHidden != next.autoHidden { sidebarAutoHidden = next.autoHidden }
    }
    @ViewBuilder private var sidebar: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { switcher = true } label: {
                        HStack { Image(systemName: "magnifyingglass"); Text("Jump to conversation"); Spacer(); Text("⌘K").font(.caption) }.foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                    Button { composing = true } label: { Image(systemName: "square.and.pencil").font(.system(size: 14)) }
                        .buttonStyle(.borderless).help("New Chat (⌘N)").accessibilityLabel("New Chat")
                }.padding(14)
                List(selection: Binding(get: { fixedConversation ?? store.shortcut.map(Self.tag) ?? store.selectedID }, set: { id in
                    guard let id else { return }
                    if let shortcut = Shortcut.allCases.first(where: { Self.tag($0) == id }) { Task { await store.openShortcut(shortcut) } }
                    else if store.conversations.contains(where: { $0.id == id }) { Task { await store.select(id) } }   // not a "Show all" row
                })) {
                    ForEach(Conversation.sidebarSections(store.conversations, limit: sectionLimitArgs.limit, expanded: sectionLimitArgs.expanded,
                                                         selected: fixedConversation ?? store.selectedID, custom: store.sections), id: \.title) {
                        section($0.title, rooms: $0.rooms, hidden: $0.hidden)
                    }
                }.listStyle(.sidebar).accessibilityIdentifier("sidebar")
                OwnStatusFooter(store: store)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { sidebarWidth = $0 } }
            .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: 230, max: Self.sidebarMaxWidth)
    }
    @ViewBuilder private var detail: some View {
            if fixedConversation == nil, store.shortcut == .home {
                HomePane(store: store).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }.toolbar { searchItem }
            } else if fixedConversation == nil, store.shortcut == .drafts {
                DraftList(store: store).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }.toolbar { searchItem }
            } else if fixedConversation == nil, let shortcut = store.shortcut {
                ShortcutList(store: store, shortcut: shortcut).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }.toolbar { searchItem }
            } else if let room, room.app == .gemini {
                GeminiPane(store: store, room: room).id(room.id).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
            } else if let room {
                // Scroll state belongs to one conversation; the toolbar stays outside so it is not duplicated on switch.
                // The thread and info panel is our own pane: SwiftUI's .inspector inside a NavigationSplitView
                // re-measures its columns without settling on macOS 27 and AppKit aborts the app.
                SidePaneSplit(open: paneOpen || (pane.threads && Self.offersThreads(room))) {
                    VStack(spacing: 0) { TimelineView(store: store, conversation: room).id(room.id) }
                        .safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
                } pane: {
                    Group {
                        if pane.info {
                            InfoPanel(store: store, room: room, search: fixedConversation == nil ? { finding = .init(scope: room) } : nil)
                        } else if let thread = pane.thread {
                            ThreadPane(store: store, room: room, thread: thread)
                        } else if pane.threads, Self.offersThreads(room) {
                            ThreadsPane(store: store, room: room)
                        }
                    }
                    // Esc closes the info panel wherever focus is; the composer's own Esc also closes it. While the composer
                    // quotes or edits, Esc is the composer's, to drop the quote or end the edit first.
                    .background {
                        let scope = store.key(room.id, nil)
                        if pane.info, store.quoting[scope] == nil, store.editing[scope] == nil {
                            Button("") { store.setPane(fixedConversation) { $0.info = false } }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
                        }
                    }
                }
                    // Customizable, as Mail's: View ▸ Customize Toolbar… or a right-click adds Info and Attach, removes items,
                    // and shows their names (Icon and Text). The title stays put.
                    .toolbar(id: "conversation") {
                        // On the left in the title's place and size, as Home and the other shortcuts show theirs.
                        ToolbarItem(id: "title", placement: .navigation) {
                            Button { store.toggleInfo(window: fixedConversation) } label: { VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    // The dot first, so it stays in one place whatever the name's length.
                                    if let partner = store.partner(in: room) { PresenceDot(presence: store.presence[partner]) }
                                    Text(room.name).font(.title3.weight(.semibold)).lineLimit(1)
                                }
                                if room.kind != .direct, !room.members.isEmpty { Text("\(room.members.count) members").font(.caption).foregroundStyle(.secondary) }
                                if let partner = store.partner(in: room), let status = store.statuses[partner] {
                                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.contentShape(Rectangle()) }
                            .buttonStyle(.plain).help("Conversation info (⇧⌘I)")
                        }
                        .customizationBehavior(.disabled)
                        .titleWithoutGlass()
                        if #available(macOS 26, *) { ToolbarSpacer(.flexible) }   // search on the right, the name on the left
                        // Web's call button; a menu, as calls and huddles may join it.
                        ToolbarItem(id: "call", placement: .primaryAction) {
                            Menu { Button("Send a Meet Link") { sendMeetLink(room.id) } } label: { Label("Video Call", systemImage: "video") }
                                .menuIndicator(.visible).help("Video call")
                        }
                        if Self.offersThreads(room) {   // the conversation's threads, as Google Chat's Active threads
                            ToolbarItem(id: "threads", placement: .primaryAction) {
                                Button { Task { await store.toggleThreads(window: fixedConversation) } } label: { Label("Threads", systemImage: "bubble.left.and.text.bubble.right") }
                                    .help("Threads")
                            }
                        }
                        ToolbarItem(id: "info", placement: .primaryAction, showsByDefault: false) {
                            Button { store.toggleInfo(window: fixedConversation) } label: { Label("Info", systemImage: "info.circle") }.help("Conversation info (⇧⌘I)")
                        }
                        ToolbarItem(id: "attach", placement: .primaryAction, showsByDefault: false) {
                            Button { commands.attach?() } label: { Label("Attach", systemImage: "paperclip") }.help("Attach files (⇧⌘A)")
                        }
                        if fixedConversation == nil {   // results open in the main window, so search lives only there
                            ToolbarItem(id: "search", placement: .primaryAction) {
                                Button { find() } label: { Label("Search", systemImage: "magnifyingglass") }.help("Search messages (⌘F)")
                            }
                        }
                    }
                    .focusedSceneValue(\.meetLinkConversation, room.id)
                    .toolbar(removing: .title)   // the conversation's name is the title; the window keeps "Parley" for its menus
                    .safeAreaInset(edge: .top, spacing: 0) { Divider() }   // the line under the header, as Home's
            } else { ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right", description: Text("Select one in the sidebar, or press ⌘K to jump to one."))
                .safeAreaInset(edge: .top, spacing: 0) { expiredBanner } }
    }
    var body: some View {
        Group {
            // A conversation's own window is just that conversation: no split view, so no sidebar or its button.
            if fixedConversation != nil { NavigationStack { detail } }
            // The detail's minimum stops a dragged sidebar from squeezing the timeline and pane off the window's edge.
            else { NavigationSplitView(columnVisibility: $columns) { sidebar } detail: {
                detail.navigationSplitViewColumnWidth(min: Self.minWidth(paneOpen: paneOpen, sidebar: 0), ideal: 700)
            } }
        }
        .frame(minWidth: Self.minWidth(paneOpen: paneOpen, sidebar: 0), minHeight: 480)
        .onChange(of: paneOpen) { _, open in
            if open { Self.makeRoom(Self.widthForPane(window: width.value, sidebar: Self.shownSidebar(fixedConversation: fixedConversation, columns: columns, measured: sidebarWidth)), in: hostWindow.window) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0; fitSidebar() }
        .background(WindowReader(ref: hostWindow, title: windowTitle, appeared: tabbed))
        .onChange(of: paneOpen) { fitSidebar() }
        .onChange(of: columns) { _, shown in
            // Shown by the user in a window too narrow for it: widen the window rather than clip.
            if shown != .detailOnly { sidebarAutoHidden = false; Self.makeRoom(Self.minWidth(paneOpen: paneOpen, sidebar: sidebarWidth), in: hostWindow.window) }
        }
        .sheet(isPresented: $switcher) { ConversationPalette(store: store) }
        .sheet(isPresented: $composing) { ConversationPalette(store: store, newChat: true) }
        .sheet(item: $store.forwarding) { message in
            ConversationPalette(store: store, then: { store.forward(message, to: $0) })
        }
        .sheet(item: findingSheet) { FinderPanel(store: store, scope: $0.scope, query: $0.query) }
        .sheet(item: sharing) { shared in ConversationPalette(store: store, then: { store.share(shared, to: $0) }, thenPrompt: "Send to a conversation or person") }
        // Handoff: the open conversation as a web page, as a browser offers it; Google Chat's iPhone and iPad app opens its links.
        .userActivity(NSUserActivityTypeBrowsingWeb, isActive: handoff != nil) { activity in
            activity.webpageURL = handoff
            activity.title = room?.name
            // Siri's on-screen awareness: the conversation in front, as the entity its actions take.
            if #available(macOS 15.2, *), let room { activity.appEntityIdentifier = EntityIdentifier(for: ConversationEntity.self, identifier: room.id) }
        }
        .onChange(of: store.newChatRequests) { if fixedConversation == nil { composing = true } }
        .onChange(of: store.newSpaceRequests) { if fixedConversation == nil { composing = false; creatingSpace = true } }
        .sheet(isPresented: $creatingSpace) { NewSpaceSheet(store: store) }
        .sheet(item: $blocking) { BlockSheet(store: store, target: $0) }
        .alert(naming?.section == nil ? "New Section" : "Rename Section", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Section name", text: $sectionName)
            Button(naming?.section == nil ? "Create" : "Rename") {
                let request = naming, name = sectionName
                Task {
                    if let section = request?.section { await store.renameSection(section, to: name) }
                    else { await store.createSection(name, moving: request?.moving) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .focusedSceneValue(\.chatCommands, commands)
        .background {
            Group {   // ⌘1 to ⌘9 stay out of the menus, as tabs' do in Safari; the main window's only
                if fixedConversation == nil { ForEach(1...9, id: \.self) { number in
                    Button("") { if let room = Conversation.atShortcut(number, in: store.conversations, limit: sectionLimitArgs.limit,
                                                                       expanded: sectionLimitArgs.expanded, selected: store.selectedID, custom: store.sections) { Task { await store.select(room.id) } } }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                } }
            }.hidden()
        }
        .overlay {
            if store.needsSignIn {
                if let signIn { WelcomeView(flow: signIn) }
                else {
                    ContentUnavailableView("Signed out of Google Chat", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                }
            }
        }
        .toolbar(store.needsSignIn ? .hidden : .automatic, for: .windowToolbar)
        // A frosted toolbar across the window, over the timeline and the side pane alike, instead of a clear one that
        // content (the wallpaper, a scrolled pane) shows through.
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .confirmationDialog("Leave “\(leaving?.name ?? "")”?", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button("Leave", role: .destructive) { if let room = leaving { Task { await store.leave(room.id) } } }
        } message: { Text("It leaves your sidebar. You can be added again later.") }
        .confirmationDialog("Delete the section “\(deletingSection?.name ?? "")”?", isPresented: Binding(get: { deletingSection != nil }, set: { if !$0 { deletingSection = nil } })) {
            Button("Delete Section", role: .destructive) { if let section = deletingSection { Task { await store.deleteSection(section) } } }
        } message: { Text("Its conversations go back to their usual sections.") }
        // An app's dialog, over the main window (ponytail: one sheet for all windows; a dialog opened from a
        // conversation's own window shows in the main one).
        .sheet(isPresented: Binding(get: { fixedConversation == nil && store.dialog != nil },
                                    set: { if !$0 { Task { await store.cancelDialog() } } })) {
            if let open = store.dialog {
                DialogSheet(open: open, submit: { await store.submitDialog(action: $0, inputs: $1) }, cancel: { Task { await store.cancelDialog() } })
            }
        }
        .overlay(alignment: .bottom) {   // an app's note, for a moment ("Poll started.")
            if let toast = store.toast {
                Text(toast).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).overlay { Capsule().strokeBorder(.separator) }
                    .padding(.bottom, 80).transition(.opacity).allowsHitTesting(false)
            }
        }
        .animation(.default, value: store.toast)
        // VoiceOver hears a note as it shows; it fades before anyone could find it.
        .onChange(of: store.toast) { _, toast in if let toast { AccessibilityNotification.Announcement(toast).post() } }
        .environment(\.paneWindow, fixedConversation)
        .alert("Couldn’t finish that", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .task(id: fixedConversation.flatMap(store.hasConversation)) {
            if let fixedConversation {   // a restored window: loads, or closes when the conversation isn't this account's
                switch store.hasConversation(fixedConversation) {
                case true?: await store.load(fixedConversation)
                case false?: dismissWindow()
                case nil: break
                }
            } else {
                // Not awaited: the permission prompt waits for the user, and until then nothing would connect or ask to sign in.
                if store.notifier != nil, NotificationSettings.current.enabled { Task { await SystemNotifier.requestAuthorization() } }
                await store.start()
            }
        }
    }
    /// Search, on the right of the toolbar: conversations and the shortcuts alike, as ⌘F works in both.
    private var searchItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { Button { find() } label: { Label("Search", systemImage: "magnifyingglass").labelStyle(.iconOnly) }.help("Search messages (⌘F)") }
    }
    @ViewBuilder private var expiredBanner: some View {
        if store.sessionExpired, let signIn { SessionExpiredBanner(flow: signIn) } else { OfflineBanner(connection: store.connection) }
    }
    /// A shortcut's sidebar row tag; conversation ids never start with it.
    private static func tag(_ shortcut: Shortcut) -> String { "shortcut:" + shortcut.rawValue }
    /// A collapsible section; which ones are collapsed is remembered across launches. Shortcuts lead with Mentions and Starred.
    /// Collapsed, its header counts its unread messages, as web Chat. `hidden`: rows Limit sidebar sections leaves out.
    /// Move to: one of my sections, a new one, or back to its default section, as Google Chat's Move conversation.
    @ViewBuilder private func moveMenu(_ room: Conversation) -> some View {
        if room.app != .gemini {
            Menu("Move To") {
                if room.section != nil { Button(room.kind == .space ? "Spaces" : room.app != nil ? "Apps" : "Direct messages") { Task { await store.moveConversation(room.id, to: nil) } } }
                ForEach(store.sections.filter { $0.kind == .custom && $0.key != room.section }) { section in
                    Button(section.name) { Task { await store.moveConversation(room.id, to: section.key) } }
                }
                Divider()
                Button("New Section…") { sectionName = ""; naming = SectionNaming(moving: room.id) }
            }
        }
    }
    /// A sidebar row as VoiceOver reads it: the name, then unread, pinned and muted when they are so.
    static func spoken(_ room: Conversation) -> String {
        ([room.name] + [room.unread > 0 ? "\(room.unread) unread" : nil, room.unreadThreads.map { "\($0) unread threads" },
                        room.pinned ? "pinned" : nil, room.muted ? "muted" : nil].compactMap { $0 })
            .joined(separator: ", ")
    }
    /// One of my own sections, by its title.
    private func customSection(_ title: String) -> SidebarSection? { store.sections.first { $0.kind == .custom && $0.name == title } }
    @ViewBuilder private func section(_ title: String, rooms: [Conversation], hidden: [Conversation]) -> some View {
        // My own sections show even when empty, as Google Chat's do, with how to fill them.
        if !rooms.isEmpty || (title == "Shortcuts" && fixedConversation == nil) || (customSection(title) != nil && fixedConversation == nil) {
            let collapsed = collapsedSections.split(separator: "\n").contains { $0 == title }
            Section(isExpanded: Binding(get: { !collapsed }, set: { collapsedSections = Self.lines(collapsedSections, title, contains: !$0) })) {
                if title == "Shortcuts" && fixedConversation == nil {
                    ForEach(Shortcut.allCases, id: \.self) { shortcut in
                        HStack {
                            Label(shortcut.title, systemImage: shortcut.icon)
                            if shortcut == .home, case let count = store.unreadThreadCount, count > 0 {   // threads with new replies, which the Dock badge counts too
                                Spacer(minLength: 0)
                                UnreadPill(count: count).accessibilityLabel("\(count) unread threads")
                            }
                            if shortcut == .drafts, case let count = store.draftCount + store.scheduled.count, count > 0 {   // as web shows it
                                Spacer(minLength: 0)
                                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityLabel("\(count) drafts")
                            }
                        }.tag(Self.tag(shortcut))
                    }
                }
                ForEach(rooms) { room in
                    HStack(spacing: 8) {
                        Avatar(name: room.name, space: room.kind == .space, size: 20, url: room.avatarURL, emoji: room.emoji)
                            .overlay(alignment: .bottomTrailing) {
                                if let partner = store.partner(in: room) { PresenceDot(presence: store.presence[partner], size: 7).offset(x: 2, y: 2) }
                            }
                        Text(room.name).fontWeight(room.unread > 0 || (room.unreadThreads ?? 0) > 0 ? .semibold : .regular).lineLimit(1).truncationMode(.tail).help(room.name)
                        Spacer(minLength: 0)
                        if room.muted { Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.secondary) }
                        if room.unread > 0 { UnreadPill(count: room.unread) }
                    }.tag(room.id)
                        // A double-click opens it in a window of its own, as in Messages; ⌘-click too, as Safari's new tab
                        // (conversation windows join as tabs). The sidebar selects one row at a time, so ⌘-click is free.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { openWindow(value: room.id) })
                        .highPriorityGesture(TapGesture().modifiers(.command).onEnded { openWindow(value: room.id) })
                        .contextMenu {
                            if room.unread > 0 { Button("Mark as Read") { Task { await store.markRead(room.id) } } }
                            else { Button("Mark as Unread") { Task { await store.markUnread(room.id) } } }
                            Button(room.pinned ? "Unpin" : "Pin") { Task { await store.setPinned(!room.pinned, room.id) } }
                            Button(room.muted ? "Unmute" : "Mute") { Task { await store.setMuted(!room.muted, room.id) } }
                            NotificationLevelPicker(store: store, room: room)
                            Button("Open in New Window") { openWindow(value: room.id) }
                            Button("Copy Link") { ChatLink.copy(ChatLink.url(room.id)) }
                            Button("Hide") { Task { await store.hide(room.id) } }
                            moveMenu(room)
                            if room.kind != .direct {
                                Divider()
                                Button("Leave…", role: .destructive) { leaving = room }
                            }
                            if room.kind == .space { Button("Block…", role: .destructive) { blocking = .space(room.id, name: room.name) } }
                            else if room.kind == .direct, room.app == nil, let partner = store.partner(in: room) {
                                Divider()
                                Button("Block…", role: .destructive) { blocking = .person(partner, name: room.name) }
                            }
                        }
                        .accessibilityElement(children: .ignore).accessibilityLabel(Self.spoken(room))
                        .draggable(ChatLink.url(room.id))   // to Safari, Notes or Finder, as its Google Chat link
                }
                if rooms.isEmpty, customSection(title) != nil {
                    Text("Right-click a conversation and choose Move To.").font(.caption).foregroundStyle(.secondary).selectionDisabled()
                }
                if !hidden.isEmpty {
                    let open = sectionLimitArgs.expanded.contains(title)
                    Button { expandedSections = Self.lines(expandedSections, title, contains: !open) } label: {
                        HStack(spacing: 8) {   // laid out as a room row, so the icon and text line up with the avatars and names
                            ShowAllIcon(open: open).frame(width: 20, height: 20)
                            Text(open ? "Show less" : "Show all").foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).selectionDisabled()   // a click on the row toggles it, never selects it
                }
                if title == "Spaces", case let count = store.invitations.count, count > 0 {
                    // Google Chat keeps invitations in its space browser; this row is the way to notice one. It opens Browse spaces.
                    Button { store.newChatRequests += 1 } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.badge").foregroundStyle(Color.accentColor).frame(width: 20, height: 20)
                            Text(Self.invitationsTitle(count))
                        }
                    }.buttonStyle(.plain).selectionDisabled()
                }
            } header: {
                HStack {
                    Text(title)
                        .contextMenu {
                            if let mine = customSection(title) {
                                Button("Rename Section…") { sectionName = mine.name; naming = SectionNaming(section: mine) }
                                Button("Move Section Up") { Task { await store.moveSection(mine, up: true) } }
                                Button("Move Section Down") { Task { await store.moveSection(mine, up: false) } }
                                Divider()
                                Button("Delete Section…", role: .destructive) { deletingSection = mine }
                            }
                        }
                    if collapsed, case let unread = rooms.filter { !$0.muted }.reduce(0, { $0 + $1.unread }), unread > 0 {
                        Spacer(minLength: 0)
                        Text("\(unread)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                            .accessibilityLabel("\(unread) unread")
                    }
                }
            }
        }
    }
}
/// One timeline row with its grouping decided from a single snapshot, so rows never index a list that changed meanwhile.
struct TimelineRow: Identifiable, Hashable {
    let message: Message
    let begins: Bool   // first of a run: same sender, gaps under 5 min
    let ends: Bool     // last of a run
    let newDay: Bool
    var seenBy: [String] = []   // names of readers whose receipt ends at this message
    var draft = false           // a thread's first message whose reply box holds a draft
    var transcriptOpen = false  // its voice message's whole transcript shows, not one line; its card's cut paragraph, all of it; or its original, not Google's translation
    var id: MessageID { message.id }

    static func rows(_ items: [Message], seen: [MessageID: [String]] = [:], drafts: Set<ThreadID> = [], transcripts: Set<MessageID> = []) -> [TimelineRow] {
        items.indices.map { index in
            var message = items[index]
            // A translated message shows its translation until opened ("View original"), which shows the original.
            if let translation = message.translation, !transcripts.contains(message.id) {
                message.text = translation.text; message.formatting = translation.formatting
            }
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            return TimelineRow(
                message: message,
                begins: previous.map { $0.isSystem || $0.sender.id != message.sender.id || message.createdAt.timeIntervalSince($0.createdAt) >= 300 } ?? true,
                ends: next.map { $0.isSystem || $0.sender.id != message.sender.id || $0.createdAt.timeIntervalSince(message.createdAt) >= 300 } ?? true,
                newDay: previous.map { !Calendar.current.isDate($0.createdAt, inSameDayAs: message.createdAt) } ?? true,
                seenBy: seen[message.id] ?? [], draft: drafts.contains(message.id), transcriptOpen: transcripts.contains(message.id))
        }
    }
}

struct TimelineView: View {
    @Bindable var store: ChatStore
    @Environment(\.paneWindow) private var paneWindow   // which window's side pane this view acts on
    let conversation: Conversation
    var thread: String? = nil
    var detached = false   // a thread in its own window
    var withHead = false   // the thread's first message leads its replies (an Ask Gemini session, as on the web)
    @State private var atBottom = true
    @State private var arrivedAway = 0   // new messages while scrolled up: the scroll-to-bottom badge
    @State private var reporting: Message?
    @State private var deleting: Message?   // asks before deleting a message for everyone
    @State private var scrollRequest = 0
    @AppStorage("timelineStyle") private var style = TimelineStyle.bubbles
    @AppStorage(Wallpaper.key(dark: false)) private var wallpaper = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var darkWallpaper = Wallpaper.none
    @AppStorage(BubblePalette.colorKey(dark: false)) private var bubbleColor = ""
    @AppStorage(BubblePalette.colorKey(dark: true)) private var darkBubbleColor = ""
    @AppStorage(Wallpaper.doodlesKey) private var doodles = true
    @State private var composerHeight: CGFloat = 0   // the floating composer's height: the timeline's bottom inset
    /// A blocked person's messages stay hidden, as Google Chat hides them.
    private var items: [Message] {
        var all = store.timeline(conversation.id, thread: thread)
        if withHead, let thread, var head = store.messages.first(where: { $0.id == thread }) {
            head.replyCount = 0   // inside its own thread, no "1 reply" link
            all.insert(head, at: 0)
        }
        let blocked = store.blockedPeople
        return blocked.isEmpty ? all : all.map { blocked.contains($0.sender.id) ? ChatStore.blockedView($0) : $0 }
    }
    private var actions: MessageRowActions {
        MessageRowActions(react: { emoji, message in Task { await store.react(emoji, to: message) } },
                          toggleTranscript: { store.toggleTranscript($0.id) },
                          dismissCard: { store.dismissCard(of: $0) },
                          clickCard: { message, card, action, inputs in await store.clickCard(message, card: card, action: action, inputs: inputs) },
                          reactCustom: { emoji, message in Task { await store.react(emoji.text, custom: emoji, to: message) } },
                          customEmoji: { await store.loadCustomEmoji(); return store.customEmoji },
                          reactors: { reaction, message in await store.reactorsLine(reaction, on: message.id) },
                          openThread: { message in Task { await store.openThread(message, window: paneWindow) } },
                          quote: { store.quote($0) },
                          forward: { store.forwarding = $0 },
                          // A forward's message lives in the conversation it came from: open it there.
                          showQuoted: { id in Task {
                              if !id.hasPrefix(conversation.id + "/"), let url = ChatLink.url(message: id), let link = ChatLink(url) { _ = await store.open(link) }
                              else { await store.showQuoted(id, in: conversation.id, window: paneWindow) }
                          } },
                          message: { person in Task { do { try await store.message([person]) } catch { store.report(error) } } },
                          person: { store.person($0, in: conversation.id) },
                          openChatLink: { link, _ in await store.open(link) },
                          retry: { message in Task { await store.retry(message) } },
                          edit: { store.edit($0) },
                          delete: { deleting = $0 },
                          star: { starred, message in Task { await store.setStarred(starred, message) } },
                          pin: { pinned, message in Task { await store.setPinned(pinned, message) } },
                          markUnread: { message in Task { await store.markUnread(from: message) } },
                          report: store.permissions[conversation.id]?.reportMessages == true ? { reporting = $0 } : nil,
                          readers: { [conversation] message in
                              conversation.kind == .space ? [] : store.readers(of: message).map { store.name(of: $0, in: conversation.id) }
                          },
                          loadAttachment: { attachment, thumbnail in try await store.attachmentData(attachment, thumbnail: thumbnail) },
                          emojiUsage: EmojiUsage())
    }
    /// The main timeline shows a window opened at an old message, away from the newest ones.
    private var isWindow: Bool { thread == nil && store.detached.contains(conversation.id) }
    /// Receipts show in the conversation's own timeline, not in a thread.
    private func rows(_ items: [Message]) -> [TimelineRow] {
        let seen = thread == nil ? store.seen(in: conversation).mapValues { $0.map { store.name(of: $0, in: conversation.id) } } : [:]
        return TimelineRow.rows(items, seen: seen, drafts: thread == nil ? store.threadsWithDrafts(in: conversation.id) : [], transcripts: store.openTranscripts)
    }
    var body: some View {
        let items = items   // filtered and sorted once per update, not once per use
        // The composer floats over the timeline, which scrolls under it with a bottom inset of the composer's height.
        Group {
            if items.isEmpty, store.loading.contains(store.key(conversation.id, thread)) {   // not empty: not loaded yet
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, composerHeight)
            } else if items.isEmpty {
                ContentUnavailableView("Start the conversation", systemImage: "bubble.left", description: Text("Send a message below."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, composerHeight)   // full width: the composer spans it
            } else {
                MessageTable(rows: rows(items), meID: store.me.id, kind: conversation.kind, style: style, look: [wallpaper.rawValue, darkWallpaper.rawValue, bubbleColor, darkBubbleColor].joined(separator: "/"), highlighted: store.highlightedID,
                             identifier: thread == nil ? "timeline" : "thread", actions: actions,
                             nearTop: { Task { await store.loadOlderIfNeeded(conversation.id, thread: thread) } },
                             nearBottom: { Task { await store.loadNewerIfNeeded(conversation.id) } }, detached: isWindow,
                             atBottomChanged: { atBottom = $0; if $0 { arrivedAway = 0 } }, scrollRequest: scrollRequest,
                             bottomInset: composerHeight)
            }
        }
        .background { WallpaperView(doodles: doodles) }
        .sheet(item: $reporting) { ReportSheet(store: store, message: $0) }
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let message = deleting { Task { await store.delete(message) } } }
        } message: { Text("It's deleted for everyone.") }
        .overlay(alignment: .top) {
            if store.loading.contains(store.key(conversation.id, thread)) && !items.isEmpty {
                ProgressView().controlSize(.small).padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if (!atBottom || isWindow) && !items.isEmpty {
                // From a window opened at an old message, the newest messages are a reload away, not a scroll.
                Button { if isWindow { Task { await store.returnToNewest(conversation.id); scrollRequest += 1 } } else { scrollRequest += 1 } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                        .floatingGlass(Circle(), interactive: true)
                        .overlay(alignment: .top) {
                            if arrivedAway > 0 {
                                Text("\(arrivedAway)").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor, in: Capsule()).offset(y: -8)
                            }
                        }
                }.buttonStyle(.plain).padding(16).padding(.bottom, composerHeight)
                    .help("Scroll to the newest message").accessibilityLabel("Scroll to the newest message")
            }
        }
        .overlay(alignment: .bottom) {
            // Its own view, so typing and the composer's own state update only the composer, not the timeline.
            ComposerBar(store: store, conversation: conversation, thread: thread, detached: detached)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .onChange(of: items.last?.id) { _, _ in if !atBottom { arrivedAway += 1 } }
        .dropDestination(for: DroppedFile.self) { dropped, _ in   // files dropped anywhere on the conversation join the draft
            let files = dropped.map(\.url).filter(\.isFileURL)
            store.attach(files, conversation: conversation.id, thread: thread)
            return !files.isEmpty
        }
    }
}

/// The floating composer under a timeline. Its own view so its state (the draft, the pickers, the typing line) updates
/// only it: inside the timeline view, every keystroke re-ran the timeline's update.
struct ComposerBar: View {
    @Bindable var store: ChatStore
    @Environment(\.paneWindow) private var paneWindow   // which window's side pane this view acts on
    let conversation: Conversation
    var thread: String? = nil
    var detached = false   // a thread in its own window
    @State private var formatBar = false   // the composer's formatting row
    @State private var gifPicker = false
    @State private var emojiPicker = false
    @State private var composerHandle = ComposerHandle()
    @State private var linking: LinkForm.Draft?   // the link form, with the selection it started from
    @State private var colorPicker = false
    @State private var recorder = VoiceRecorder()
    /// Who's typing here, or the app at work, in a thought bubble at the end of the conversation (the timeline makes room).
    @ViewBuilder private var typingBubble: some View {
        let known = { (id: PersonID) in store.person(id, in: conversation.id) ?? Person(id: id, name: store.name(of: id, in: conversation.id)) }
        if let activity = store.activity(conversation.id, thread: thread) {
            TypingBubble(typists: [known(activity.person)], activity: activity.label,
                         dots: conversation.app == .gemini ? [Color(red: 0.31, green: 0.49, blue: 0.95), Color(red: 0.54, green: 0.39, blue: 0.91), Color(red: 0.82, green: 0.38, blue: 0.62)]
                                                           : [.secondary, .secondary, .secondary])
        } else if case let typists = store.typists(conversation.id, thread: thread), !typists.isEmpty {
            TypingBubble(typists: typists.map(known), showsName: conversation.kind != .direct)   // a DM's picture says who
        }
    }
    private var blockedPartner: PersonID? {
        guard thread == nil, conversation.kind == .direct, let partner = store.partner(in: conversation), store.blockedPeople.contains(partner) else { return nil }
        return partner
    }
    var body: some View {
        Group {
            if let blockedPartner { BlockedCover(store: store, person: blockedPartner, name: conversation.name) } else { composer }
        }
            .onChange(of: conversation.id) { recorder.cancel() }   // a recording belongs to the conversation it started in
            .onDisappear { recorder.cancel() }
            .onAppear { composerHandle.askForLink = { linking = LinkForm.Draft(text: composerHandle.selectedText) } }
            .sheet(item: $linking) { draft in
                LinkForm(draft: draft) { url, text in composerHandle.link(url, text: text) }
            }
    }
    private func formatButton(_ icon: String, _ help: String, _ action: Selector) -> some View {
        Button { NSApp.sendAction(action, to: nil, from: nil) } label: { Image(systemName: icon).frame(width: 26, height: 22) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
    private var scope: String { store.key(conversation.id, thread) }
    private var pendingFiles: [Attachment] { store.draftAttachments[scope] ?? [] }
    private func attach(_ urls: [URL]) { store.attach(urls, conversation: conversation.id, thread: thread) }
    private func chooseFiles() { ChatView.chooseFiles { attach($0) } }
    /// A pending attachment above the field: a thumbnail for images, the file's icon otherwise, and a remove button.
    private func chip(_ file: Attachment) -> some View {
        HStack(spacing: 6) {
            PendingThumbnail(file: file)
            Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .leading)
            Button { store.detach(file, conversation: conversation.id, thread: thread) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(file.name)")
        }
        .padding(4).padding(.trailing, 4)
        .floatingGlass(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var draft: String { store.drafts[scope] ?? "" }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingFiles.isEmpty || store.quoting[scope]?.forwardedFrom != nil }
    /// Floating glass pieces over the timeline, as Telegram lays them out: a round attach button, the field (with
    /// Aa, emoji and GIF at its end) and a round send button; the edit, reply, formatting, upload and typing rows
    /// float as small capsules above the field.
    private var composer: some View {
        FloatingGlassGroup {
            VStack(alignment: .leading, spacing: 6) {
                typingBubble   // under the timeline's avatars, which line up with the attach button
                Group {
                    if formatBar {
                        // Web's toolbar, in its order; the field's ComposerTextView is first responder and takes the actions.
                        HStack(spacing: 2) {
                            formatButton("bold", "Bold (⌘B)", #selector(ComposerTextView.formatBold(_:)))
                            formatButton("italic", "Italic (⌘I)", #selector(ComposerTextView.formatItalic(_:)))
                            formatButton("underline", "Underline (⌘U)", #selector(ComposerTextView.formatUnderline(_:)))
                            // Web's colour button: an "A" underlined in the current colour, opening a row of dots.
                            Button { colorPicker.toggle() } label: {
                                Image(systemName: "character").overlay(alignment: .bottom) {
                                    Capsule().fill(composerHandle.view?.currentColor.map { Color(nsColor: NSColor(rgb: $0.argb & 0xFF_FFFF)) } ?? .secondary)
                                        .frame(width: 13, height: 2.5).offset(y: 3)
                                }.frame(width: 26, height: 22)
                            }
                            .buttonStyle(.borderless).help("Text color").accessibilityLabel("Text color")
                            .popover(isPresented: $colorPicker, arrowEdge: .top) {
                                ColorDots(current: composerHandle.view?.currentColor) { color in
                                    composerHandle.view?.color(color); colorPicker = false
                                    if let view = composerHandle.view { view.window?.makeFirstResponder(view) }
                                }
                            }
                            formatButton("strikethrough", "Strikethrough (⇧⌘X)", #selector(ComposerTextView.formatStrike(_:)))
                            Divider().frame(height: 16)
                            formatButton("list.bullet", "Bulleted list (⇧⌘8)", #selector(ComposerTextView.formatList(_:)))
                            Divider().frame(height: 16)
                            formatButton("text.quote", "Quote (⌘')", #selector(ComposerTextView.formatQuote(_:)))
                            formatButton("link", "Link (⇧⌘K)", #selector(ComposerTextView.formatLink(_:)))
                            Divider().frame(height: 16)
                            formatButton("chevron.left.forwardslash.chevron.right", "Code (⇧⌘C)", #selector(ComposerTextView.formatCode(_:)))
                            formatButton("curlybraces.square", "Code block (⌥⇧⌘C)", #selector(ComposerTextView.formatCodeBlock(_:)))
                        }.padding(.horizontal, -6).floatingCapsule()
                    }
                    if let next = store.scheduled(in: conversation.id, thread: thread).first, let at = next.schedule?.at {   // as web says it
                        let more = store.scheduled(in: conversation.id, thread: thread).count - 1
                        Button { Task { await store.openShortcut(.drafts) } } label: {
                            Label(more > 0 ? "Scheduled for \(ScheduledSend.when(at, inSentence: true)), and \(more) more"
                                             : "Scheduled for \(ScheduledSend.when(at, inSentence: true))",
                                  systemImage: "clock").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.buttonStyle(.plain).help("See scheduled messages").floatingCapsule()
                    }
                    if store.uploading(conversation.id, thread: thread) > 0 {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Uploading…").font(.caption).foregroundStyle(.secondary) }.floatingCapsule()
                    }
                    if !pendingFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(pendingFiles, id: \.self) { chip($0) } }.padding(4)
                        }
                    }
                }.padding(.leading, Self.control + 8)   // above the field, not the attach button
                HStack(alignment: .bottom, spacing: 8) {
                    if recorder.isRecording {   // Telegram's recording bar: ✕ cancels (Esc), the round button sends (Return)
                        Button { recorder.cancel() } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), interactive: true)
                        }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cancel recording (Esc)").accessibilityLabel("Cancel recording")
                        RecordingBar(recorder: recorder).frame(maxWidth: .infinity, minHeight: Self.control)
                            .floatingGlass(RoundedRectangle(cornerRadius: Self.control / 2, style: .continuous))
                        Button(action: sendRecording) {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), tint: .accentColor, interactive: true)
                        }.buttonStyle(.plain).keyboardShortcut(.defaultAction).help("Send voice message (Return)").accessibilityLabel("Send voice message")
                    } else {
                        Button(action: chooseFiles) {
                            Image(systemName: "paperclip").font(.system(size: 17)).foregroundStyle(.secondary)
                                .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), interactive: true)
                        }.buttonStyle(.plain).help("Attach files").accessibilityLabel("Attach files")
                        field
                        if canSend || store.editingID(conversation.id, thread: thread) != nil {
                            Button { Task { await store.send(conversation: conversation.id, thread: thread) } } label: {
                                Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(canSend ? .white : .secondary)
                                    .frame(width: Self.control, height: Self.control)
                                    .floatingGlass(Circle(), tint: canSend ? .accentColor : nil, interactive: true)
                            }.buttonStyle(.plain).disabled(!canSend).help("Send message: Return. A new line: Shift-Return. Right-click to schedule.").accessibilityLabel("Send message")
                            .contextMenu {
                                ScheduleMenu(enabled: store.canSchedule(conversation: conversation.id, thread: thread)) { date in
                                    Task { await store.schedule(conversation: conversation.id, thread: thread, at: date) }
                                } custom: { pickingSchedule = true }
                            }
                            .sheet(isPresented: $pickingSchedule) {
                                ScheduleSheet(title: "Schedule Send") { date in
                                    pickingSchedule = false
                                    if let date { Task { await store.schedule(conversation: conversation.id, thread: thread, at: date) } }
                                }
                            }
                        } else {   // an empty field offers a voice message instead, as Telegram does
                            Button { Task { do { try await recorder.start() } catch { store.report(error) } } } label: {
                                Image(systemName: "mic").font(.system(size: 17)).foregroundStyle(.secondary)
                                    .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), interactive: true)
                            }.buttonStyle(.plain).help("Record voice message").accessibilityLabel("Record voice message")
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
        }
    }
    /// Ends this composer's edit and clears the message's text from it.
    private func endEdit() { store.endEdit(conversation: conversation.id, thread: thread) }
    private func sendRecording() {
        guard let recording = recorder.finish() else { return }
        Task { await store.sendVoice(recording.file, duration: recording.duration, waveform: recording.levels, conversation: conversation.id, thread: thread) }
    }
    @State private var pickingSchedule = false
    private static let control: CGFloat = 42   // round buttons, and the field's height on one line
    @State private var fieldHeight: CGFloat = 0   // the text view's laid-out height; wrapped paragraphs count, not only newlines
    /// The text capsule: the native field, a placeholder while empty, and Aa, emoji and GIF at its end.
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editing = store.editingID(conversation.id, thread: thread).flatMap({ id in store.messages.first { $0.id == id } }) { editHeader(editing) }
            else if let quote = store.quoting[scope] { quoteHeader(quote) }
            fieldRow
        }
        .floatingGlass(RoundedRectangle(cornerRadius: Self.control / 2, style: .continuous))
    }
    /// The reply or forward inside the field, as Telegram shows it: an accent bar, who, and one line of the message.
    private func quoteHeader(_ quote: QuotedMessage) -> some View {
        accessoryHeader(title: quote.forwardedFrom == nil ? "Reply to \(quote.sender)" : "Forward from \(quote.sender)", text: quote.text, media: quote.media,
                        closeHelp: quote.forwardedFrom == nil ? "Cancel reply" : "Cancel forward", close: { store.quoting[scope] = nil }) {
            guard let id = quote.id else { return }
            Task {
                if !id.hasPrefix(conversation.id + "/"), let url = ChatLink.url(message: id), let link = ChatLink(url) { _ = await store.open(link) }
                else { await store.showQuoted(id, in: conversation.id, window: paneWindow) }
            }
        }
    }
    /// Telegram's edit panel: the message being edited, one line; its attachments stay, as in Google Chat.
    private func editHeader(_ message: Message) -> some View {
        accessoryHeader(title: "Edit message", text: QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments),
                        media: message.attachments.first { $0.kind == .image || $0.kind == .video }, closeHelp: "Cancel editing",
                        close: endEdit) {
            Task { await store.showQuoted(message.id, in: conversation.id, window: paneWindow) }
        }
    }
    private func accessoryHeader(title: String, text: String, media: Attachment?, closeHelp: String, close: @escaping () -> Void, show: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color.accentColor).frame(width: 3)
            if let media {
                Thumbnail(attachment: media, load: { try await store.attachmentData($0, thumbnail: $1) }).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor).lineLimit(1)
                Text(text).font(.callout).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: show)   // as in Telegram, a click shows the message
            .help("Show the message")
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("\(closeHelp) (Esc)").accessibilityLabel(closeHelp)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 14).padding(.trailing, 16).padding(.top, 10)
    }
    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            NativeComposer(text: draft, formatting: store.draftFormatting[scope] ?? [],
                           change: { text, formatting in
                               store.setDraft(text, formatting: formatting, conversation: conversation.id, thread: thread)
                               Task { await store.typed(text, conversation: conversation.id, thread: thread) }
                           }, send: { Task { await store.send(conversation: conversation.id, thread: thread) } }, editLast: {
                if let last = store.timeline(conversation.id, thread: thread).last(where: { $0.sender.id == store.me.id }) { store.edit(last) }
            }, cancel: {   // Esc: drops the quote first, then ends an edit and closes the thread
                if store.quoting[scope] != nil { store.quoting[scope] = nil }
                else if store.editing[scope] != nil { endEdit() }
                else if !detached {   // a thread window leaves the main window's panes alone
                    let closing = composerHandle.view, window = closing?.window
                    store.setPane(paneWindow) { $0.thread = nil; $0.info = false }
                    // Out of a thread: the conversation's composer has the keyboard again.
                    if thread != nil { DispatchQueue.main.async { if let main = ComposerTextView.all(in: window).first(where: { $0 !== closing }) { window?.makeFirstResponder(main) } } }
                }
            }, attach: attach,
               members: store.mentionSuggestions(conversation.id), spaces: store.conversations, needMembers: { Task { await store.loadMembers(conversation.id) } },
               customEmoji: store.customEmoji, needCustomEmoji: { Task { await store.loadCustomEmoji() } },
               searchCustomEmoji: { query in store.searchCustomEmoji(query) },
               slashCommands: store.slashCommands[conversation.id] ?? [],
               needSlashCommands: { query in Task { await store.loadSlashCommands(conversation.id, query: query) } },
               runCommand: { command in Task { await store.run(command, in: conversation.id) } },
               loadImage: { try await store.attachmentData($0, thumbnail: $1) },
               // A thread's composer takes the keyboard as it opens.
               focus: store.quoting[scope]?.id ?? thread, handle: composerHandle, height: { if fieldHeight != $0 { fieldHeight = $0 } })
            .frame(minWidth: 60).frame(height: min(130, max(Self.control, fieldHeight)))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {   // aligned with the text view's inset and line padding
                    Text(ChatView.composerPrompt(conversation, thread: thread)).foregroundStyle(.tertiary).padding(.leading, 13).padding(.top, 11).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            Button { formatBar.toggle() } label: { Text("Aa").font(.system(size: 14, weight: .semibold)).fixedSize().foregroundStyle(formatBar ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).padding(.bottom, 13).help(formatBar ? "Hide formatting" : "Show formatting").accessibilityLabel("Formatting")
            Button { emojiPicker.toggle() } label: { Image(systemName: "face.smiling").font(.system(size: 18)).foregroundStyle(emojiPicker ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).padding(.bottom, 11).help("Emoji").accessibilityLabel("Emoji")
                .popover(isPresented: $emojiPicker, arrowEdge: .top) { composerHandle.emojiPicker(custom: { await store.loadCustomEmoji(); return store.customEmoji },
                                                                                       loadImage: { try await store.attachmentData($0, thumbnail: $1) },
                                                                                       close: { emojiPicker = false }) }
            Button { gifPicker.toggle() } label: { Text("GIF").font(.system(size: 11, weight: .bold)).fixedSize().padding(.horizontal, 3).overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.5)).foregroundStyle(gifPicker ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).padding(.bottom, 14).help("GIF").accessibilityLabel("GIF")
                .popover(isPresented: $gifPicker, arrowEdge: .top) {
                    GifPicker(pick: { gif in Task { await store.sendGif(gif, conversation: conversation.id, thread: thread) } }, close: { gifPicker = false })
                }
        }
        .padding(.trailing, 14)
    }}

/// Follow or unfollow a thread, as Google Chat's thread header offers it: a filled bell while followed.
/// A file waiting in the composer: a picture's thumbnail, made once off the main thread (the composer redraws on every
/// keystroke, and reading a large photo there made typing stutter), or the file's icon.
struct PendingThumbnail: View {
    let file: Attachment
    @State private var picture: NSImage?
    private var path: String { file.url?.path(percentEncoded: false) ?? "" }
    var body: some View {
        Image(nsImage: picture ?? NSWorkspace.shared.icon(forFile: path))
            .resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
            .task(id: path) { if file.kind == .image, let url = file.url { picture = await Self.load(url) } }
    }
    /// 64 px on the longer side: the chip is 32 pt, on a Retina screen.
    nonisolated static func load(_ url: URL) async -> NSImage? {
        await Task.detached { (try? Data(contentsOf: url)).flatMap { ImageCache.decode($0, maxPixels: 64) } }.value
    }
}

struct ThreadFollowButton: View {
    let store: ChatStore
    let thread: ThreadID
    /// What a click does.
    var label: String { store.isFollowing(thread) ? "Unfollow thread" : "Follow thread" }
    func toggle() async { await store.setFollowing(!store.isFollowing(thread), thread: thread) }
    var body: some View {
        let following = store.isFollowing(thread)
        Button { Task { await toggle() } } label: { Image(systemName: following ? "bell.fill" : "bell").contentTransition(.symbolEffect(.replace)) }
            .buttonStyle(.plain)
            .help(following ? "Unfollow thread: its replies stop notifying you" : "Follow thread: its replies notify you")
            .accessibilityLabel(label)
    }
}

/// On macOS 26 the floating pieces are Liquid Glass and blend when close; earlier, material shapes.
/// The thread pane: the thread's first message over its replies and composer, beside a conversation or Home.
struct ThreadPane: View {
    @Bindable var store: ChatStore
    @Environment(\.paneWindow) private var paneWindow   // which window's side pane this view acts on
    let room: Conversation
    let thread: ThreadID
    var detached = false   // in its own window, which has its own close button
    var session: String? = nil   // an Ask Gemini session: the question is the title, with no first message over the replies
    @Environment(\.openWindow) private var openWindow
    @State private var parentExpanded = false   // the first message beyond its first four lines
    @State private var emojiLoads = 0   // custom emoji pictures arrived: the header redraws
    /// The pane's thread in a window of its own; the pane closes.
    private func detach() { if let ref = store.detachThread(in: room.id) { openWindow(value: ref) } }
    var body: some View {
        VStack(spacing: 0) {
            // An Ask Gemini session is a page of its own: its toolbar has the back button, so no pane header.
            if !detached, session == nil {
                HStack(spacing: 12) {
                    Text("Thread").font(.headline).lineLimit(1).truncationMode(.tail); Spacer()
                    ThreadFollowButton(store: store, thread: thread)
                    Button(action: detach) { Image(systemName: "macwindow.badge.plus") }
                        .buttonStyle(.borderless).help("Open in new window").accessibilityLabel("Open in New Window")
                    Button { store.setPane(paneWindow) { $0.thread = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Close").accessibilityLabel("Close")
                }.padding()
                Divider()
            }
            if session == nil, let parent = store.messages.first(where: { $0.id == thread }) {
                // A long first message would push the replies out of the pane: four lines, a click shows the rest.
                // A message with no text shows its picture and what it carried ("Photo", the file's name…), as quotes do.
                HStack(alignment: .top, spacing: 8) {
                    if let media = parent.attachments.first(where: { $0.kind == .image || $0.kind == .video }) {
                        Thumbnail(attachment: media, load: { try await store.attachmentData($0, thumbnail: $1) }).frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading) {
                        Text(parent.sender.name).font(.caption).foregroundStyle(.secondary)
                        // The timeline's own text: formatting, mentions, links and custom emoji as in the bubble.
                        NativeMessageText(text: parent.text.isEmpty ? QuotedMessage.summary(text: "", attachments: parent.attachments) : parent.text,
                                          formatting: parent.text.isEmpty ? [] : parent.formatting, own: false, lines: parentExpanded ? 0 : 4,
                                          maxWidth: .infinity, redraw: emojiLoads)
                            .task(id: parent.id) { await loadEmoji(in: parent) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .contentShape(Rectangle()).onTapGesture { parentExpanded.toggle() }
                .help(parentExpanded ? "Show less" : "Show the whole message")
                .onChange(of: thread) { parentExpanded = false }
                Divider()
            }
            TimelineView(store: store, conversation: room, thread: thread, detached: detached, withHead: session != nil).id(thread)
        }
        // ⌘O while the pane has the keyboard pops the thread out, as its button does.
        .focusedValue(\.openFocusedInWindow, detached ? nil : FocusedOpen(title: "Open Thread in New Window", open: detach))
    }
    /// Its custom emoji's pictures, which the text draws from `ImageCache` once they are there.
    private func loadEmoji(in message: Message) async {
        for range in message.formatting {
            guard case .customEmoji(let emoji) = range.style, !emoji.deleted, let picture = emoji.image, ImageCache.cached(picture) == nil else { continue }
            if (try? await ImageCache.load(picture, store.attachmentData)) != nil { emojiLoads += 1 }
        }
    }
}

/// Web's text colour picker: the default colour, then its five, the current one checked.
struct ColorDots: View {
    let current: TextColor?
    let pick: (TextColor?) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach([nil] + TextColor.allCases.map(Optional.some), id: \.self) { (color: TextColor?) in
                Button { pick(color) } label: {
                    Circle().fill(color.map { Color(nsColor: NSColor(rgb: $0.argb & 0xFF_FFFF)) } ?? Color(nsColor: .textColor))
                        .overlay { if color == current { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Self.check(on: color)) } }
                        .overlay(Circle().stroke(.quaternary))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).help(color?.name ?? "Default").accessibilityLabel(color?.name ?? "Default color")
            }
        }
        .padding(12)
    }
    /// A checkmark that shows on its dot: the default dot is the text colour (dark or light), amber is light.
    private static func check(on color: TextColor?) -> Color {
        switch color { case nil: Color(nsColor: .textBackgroundColor); case .amber?: .black; default: .white }
    }
}

/// Add Link, as Mail's ⌘K asks: the text (the selection, if any) and the address.
struct LinkForm: View {
    struct Draft: Identifiable { let id = UUID(); var text: String }
    let draft: Draft
    let add: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var address = ""
    /// The address as typed, with https:// when it has no scheme ("example.com").
    nonisolated static func url(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://" + trimmed
        return URL(string: full).flatMap { $0.host() != nil || $0.scheme == "mailto" ? $0 : nil }
    }
    var body: some View {
        Form {
            TextField("Text", text: $text, prompt: Text("Shown in the message"))
            TextField("Link", text: $address, prompt: Text("https://"))
        }
        .padding(20).frame(width: 380)
        .onAppear { text = draft.text; if Self.url(draft.text) != nil, draft.text.contains(".") { address = draft.text } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Link") { if let url = Self.url(address) { add(url, text); dismiss() } }.disabled(Self.url(address) == nil)
            }
        }
    }
}

extension FocusedValues {
    /// The focused window's conversation, for File ▸ Send a Meet Link.
    @Entry var meetLinkConversation: ConversationID?
}

/// File ▸ Send a Meet Link (⇧⌘M), for the conversation in the focused window.
struct MeetLinkMenuItem: View {
    let store: ChatStore
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

/// A thread popped out of the pane: its first message and replies with their composer, as the pane shows them.
struct ThreadWindow: View {
    @Bindable var store: ChatStore
    let ref: ThreadRef
    var body: some View {
        Group {
            if let room = store.conversations.first(where: { $0.id == ref.conversation }) {
                ThreadPane(store: store, room: room, thread: ref.thread, detached: true).navigationTitle("Thread").navigationSubtitle(room.name)
            } else { ProgressView().navigationTitle("Thread") }
        }
        .frame(minWidth: ChatView.paneWidth, minHeight: 400)
        // A restored window loads its thread, or closes when the conversation isn't this account's.
        .task(id: store.hasConversation(ref.conversation)) {
            switch store.hasConversation(ref.conversation) {
            case true?: await store.load(ref.conversation, thread: ref.thread)
            case false?: dismissWindow()
            case nil: break
            }
        }
    }
    @Environment(\.dismissWindow) private var dismissWindow
}

/// Home's list, with a thread row's thread open in the thread pane to its right.
struct HomePane: View {
    @Bindable var store: ChatStore
    var body: some View {
        SidePaneSplit(open: store.threadID != nil && store.selected != nil) {
            ShortcutList(store: store, shortcut: .home)
        } pane: {
            if let thread = store.threadID, let room = store.selected { ThreadPane(store: store, room: room, thread: thread) }
        }
    }
}

/// A timeline (or list) with the thread or info pane to its right, as wide as the user dragged its divider: from
/// `paneWidth` to `paneMaxWidth`, and never so wide the timeline gets less than its minimum. The width is remembered.
struct SidePaneSplit<Main: View, Pane: View>: View {
    var open: Bool
    @ViewBuilder var main: Main
    @ViewBuilder var pane: Pane
    @AppStorage("sidePaneWidth") private var wanted: Double = ChatView.paneWidth
    @State private var room: CGFloat = 0   // this view's width, the timeline's and the pane's together
    @State private var dragStart: CGFloat?
    /// The pane's width: as wanted, within its bounds and what `room` leaves beside the timeline's minimum.
    static func shown(wanted: CGFloat, room: CGFloat) -> CGFloat {
        let most = min(ChatView.paneMaxWidth, max(ChatView.paneWidth, room - ChatView.timelineMinWidth - 1))
        return min(max(wanted, ChatView.paneWidth), most)
    }
    var body: some View {
        let width = Self.shown(wanted: wanted, room: room)
        HStack(spacing: 0) {
            main.frame(minWidth: ChatView.timelineMinWidth, maxWidth: .infinity)
            if open {
                Divider().overlay {
                    // A wider grip than the line, as a split view's divider has.
                    Color.clear.frame(width: 7).contentShape(Rectangle()).pointerStyle(.columnResize)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                wanted = Self.shown(wanted: start - drag.translation.width, room: room)
                            }
                            .onEnded { _ in dragStart = nil })
                }.zIndex(1)
                pane.frame(width: width)
            }
        }
        // Past the room for the widest pane beside the narrowest timeline, more room changes nothing: no redraw per frame of a resize.
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, ChatView.paneMaxWidth + ChatView.timelineMinWidth + 1) } action: { room = $0 }
    }
}

struct FloatingGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
    }
}
extension View {
    @ViewBuilder func floatingGlass(_ shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background { shape.fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.regularMaterial)) }
                .overlay(shape.stroke(.quaternary)).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }
    /// A small floating row above the composer's field.
    func floatingCapsule() -> some View {
        padding(.horizontal, 12).padding(.vertical, 6).floatingGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
/// An unread count in a sidebar or list row: white on the accent color.
struct UnreadPill: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 11, weight: .semibold, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule()).foregroundStyle(.white).monospacedDigit().fixedSize()
    }
}
/// The main window's actions for the menu bar; each acts on the window in front.
struct ChatCommands {
    var find: (() -> Void)?   // nil in a conversation's own window
    var jump: () -> Void
    var info: () -> Void
    var editLast: () -> Void
    var unread: (_ forward: Bool) -> Void
    /// The conversation on screen, which the Conversation menu acts on; nil on Home and the other shortcuts.
    var room: Conversation? = nil
    var threads: (() -> Void)? = nil        // nil where the conversation has no threads
    var threadsShown = false                // the Threads list is on screen, for the item's title
    var openInWindow: (() -> Void)? = nil
    var newSection: (() -> Void)? = nil
    var leave: (() -> Void)? = nil          // asks first
    var block: (() -> Void)? = nil          // asks first
    var attach: (() -> Void)? = nil
}
extension EnvironmentValues {
    /// The window a view is in, for its side pane: nil in the main window, else the conversation a conversation window shows.
    @Entry var paneWindow: ConversationID?
}
extension FocusedValues {
    @Entry var chatCommands: ChatCommands?
    /// Conversation ▸ Open in New Window for what has the keyboard, over the conversation on screen: the rows selected in
    /// Home, Mentions or Starred, or the thread pane.
    @Entry var openFocusedInWindow: FocusedOpen?
}
/// What Open in New Window opens for the view with the keyboard, and the menu item's title for it.
struct FocusedOpen {
    var title = "Open in New Window"
    var open: () -> Void
}

/// Message search (⌘F).
struct FinderPanel: View {
    /// What to search, carried by the sheet's item so the panel never opens with a stale scope: ⌘F's conversation
    /// starts as the "said in" filter, which can be changed or cleared like any other.
    struct Request: Identifiable { var id = UUID(); let scope: Conversation?; var query = "" }
    @Bindable var store: ChatStore
    @State private var query: String
    @State private var filters: SearchFilters
    init(store: ChatStore, scope: Conversation? = nil, query: String = "") {
        self.store = store
        _query = State(initialValue: query)
        _filters = State(initialValue: SearchFilters(saidIn: scope.map { [$0.id] } ?? []))
    }
    @State private var selected: String?
    @State private var searching = false
    @Environment(\.dismiss) private var dismiss
    private struct Ask: Equatable { var query: String; var filters: SearchFilters }
    /// What the list shows when it has no results: a prompt before anything is asked, progress, or that nothing matched.
    @ViewBuilder private var noResults: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty && filters.isEmpty {
            ContentUnavailableView("Search messages", systemImage: "magnifyingglass", description: Text("Type words, or pick a person, a conversation or a date."))
        } else if searching {
            ProgressView()
        } else {
            ContentUnavailableView.search(text: query)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            TextField("Search messages", text: $query).textFieldStyle(.plain).font(.title3).padding(.horizontal, 18).padding(.top, 18)
                .onKeyPress(.downArrow) { move(1); return .handled }   // through the results without leaving the field
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .padding(.bottom, 10).onSubmit { choose() }
            SearchChips(store: store, filters: $filters).padding(.horizontal, 18).padding(.bottom, 10)
            Divider()
            List(selection: $selected) {
                ForEach(store.searchResults) { message in
                    SearchResultRow(message: message, conversation: store.conversations.first { $0.id == message.conversationID }?.name ?? "Conversation",
                                    load: { try await store.attachmentData($0, thumbnail: $1) })
                        .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())   // the whole row opens it
                        .tag(message.id).onTapGesture { selected = message.id; choose() }
                }
            }.frame(height: 280)
            .overlay { if store.searchResults.isEmpty { noResults } }
            HStack { Text("Searches Google Chat").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
        }.frame(width: 500)
            .task(id: Ask(query: query, filters: filters)) {
                try? await Task.sleep(for: .milliseconds(250))   // one request per pause in typing, not per keystroke
                guard !Task.isCancelled else { return }
                searching = true; defer { searching = false }
                await store.search(query, filters: filters); selected = store.searchResults.first?.id
            }
    }
    private func move(_ step: Int) {
        let ids = store.searchResults.map(\.id)
        guard !ids.isEmpty else { return }
        let at = selected.flatMap(ids.firstIndex) ?? (step > 0 ? -1 : ids.count)
        selected = ids[min(max(at + step, 0), ids.count - 1)]
    }
    private func choose() {
        guard let selected else { return }
        Task {
            if let message = store.searchResults.first(where: { $0.id == selected }) { await store.jump(message) }
            dismiss()
        }
    }
}

/// A search result as Google Chat's web draws it: who and where, the text, then what the message carries. Pictures show
/// as thumbnails and files and Drive links by name, so a picture or a document can be found by sight.
struct SearchResultRow: View {
    let message: Message
    let conversation: String
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    static let thumbnail: CGFloat = 56
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.sender.name, size: 28, url: message.sender.avatarURL)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(message.sender.name) · \(conversation)").font(.caption).foregroundStyle(.secondary)
                if !message.text.isEmpty { Text(message.text).lineLimit(3) }
                let shown = Self.shown(message.attachments)
                if !shown.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, attachment in item(attachment) }
                    }
                }
            }
        }
    }
    /// Cards and calls are not things to find.
    static func shown(_ attachments: [Attachment]) -> [Attachment] { attachments.filter { $0.kind != .card && $0.kind != .call } }
    /// A link's symbol, by the Drive file it opens, or a voice message's; nil for a file, which shows the Finder's icon for its type.
    static func symbol(_ attachment: Attachment) -> String? {
        if attachment.kind == .voice { return "waveform" }
        guard attachment.kind == .link else { return nil }
        let kind = attachment.contentType + (attachment.url?.path() ?? "")
        return kind.contains("document") ? "doc.text" : kind.contains("spreadsheet") ? "tablecells"
            : kind.contains("presentation") ? "rectangle.on.rectangle" : "link"
    }
    @ViewBuilder private func item(_ attachment: Attachment) -> some View {
        if attachment.kind == .image || attachment.kind == .video {
            Thumbnail(attachment: attachment, load: load).frame(width: Self.thumbnail, height: Self.thumbnail)
        } else {
            HStack(spacing: 5) {
                if let symbol = Self.symbol(attachment) {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: attachment.utType ?? .data)).resizable().frame(width: 16, height: 16)
                }
                Text(attachment.kind == .voice ? "Voice message" : attachment.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .help(attachment.name)
        }
    }
}

/// Google Chat's search chips: From, Date, Has and Mentions me. A chip in use is tinted and says what it picked.
struct SearchChips: View {
    let store: ChatStore
    @Binding var filters: SearchFilters
    @State private var pickingPeople = false
    @State private var pickingConversations = false
    @State private var pickingDates = false
    var body: some View {
        HStack(spacing: 6) {
            chip(filters.from.isEmpty ? "From" : "From: " + ListFormatter.localizedString(byJoining: filters.from.map(\.name)), on: !filters.from.isEmpty) {
                pickingPeople = true
            }
            .popover(isPresented: $pickingPeople, arrowEdge: .bottom) { PeoplePicker(store: store, picked: $filters.from) }
            let names = filters.saidIn.compactMap { id in store.conversations.first { $0.id == id }?.name }
            chip(names.isEmpty ? "Said in" : "Said in: " + ListFormatter.localizedString(byJoining: names), on: !filters.saidIn.isEmpty) {
                pickingConversations = true
            }
            .popover(isPresented: $pickingConversations, arrowEdge: .bottom) { ConversationPicker(store: store, picked: $filters.saidIn) }
            Menu {
                Button("Any Time") { filters.after = nil; filters.before = nil }
                ForEach(SearchFilters.Age.allCases, id: \.self) { age in
                    Button(age.rawValue) { filters.after = nil; filters.before = age.before(now: .now) }
                }
                Button("Custom Range…") { pickingDates = true }
            } label: { Text(dateTitle) }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
                .tint(filters.after != nil || filters.before != nil ? .accentColor : nil)
            Menu {
                ForEach(SearchFilters.Kind.allCases, id: \.self) { kind in
                    Toggle(kind.rawValue, isOn: Binding(get: { filters.has.contains(kind) }, set: { _ in filters.toggle(kind) }))
                }
            } label: { Text(filters.has.isEmpty ? "Has" : "Has: " + SearchFilters.Kind.allCases.filter(filters.has.contains).map(\.rawValue).joined(separator: ", ")) }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
                .tint(filters.has.isEmpty ? nil : .accentColor)
            chip("Mentions me", on: filters.mentionsMe) { filters.mentionsMe.toggle() }
            Spacer(minLength: 0)
            if !filters.isEmpty { Button("Clear") { filters = SearchFilters() }.buttonStyle(.link).controlSize(.small) }
        }
        .sheet(isPresented: $pickingDates) {
            DateRangeSheet { range in
                pickingDates = false
                if let range { filters.after = range.lowerBound; filters.before = range.upperBound }
            }
        }
    }
    private var dateTitle: String {
        switch (filters.after, filters.before) {
        case (nil, nil): return "Date"
        case (nil, let before?):
            return SearchFilters.Age.allCases.first { abs($0.before(now: .now).timeIntervalSince(before)) < 86_400 }?.rawValue
                ?? "Before \(before.formatted(date: .abbreviated, time: .omitted))"
        case (let after?, let before):
            let end = before.map { $0.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted) } ?? "now"
            return "\(after.formatted(date: .abbreviated, time: .omitted)) – \(end)"
        }
    }
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.small).tint(on ? .accentColor : nil).lineLimit(1)
    }
}

/// People to search messages from: me, then anyone found by name.
private struct PeoplePicker: View {
    let store: ChatStore
    @Binding var picked: [Person]
    @State private var query = ""
    @State private var found: [Person] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name or email", text: $query).textFieldStyle(.roundedBorder)
            ForEach([store.me] + found.filter { $0.id != store.me.id }, id: \.id) { person in
                Toggle(isOn: Binding(get: { picked.contains { $0.id == person.id } }, set: { on in
                    if on { picked.append(person) } else { picked.removeAll { $0.id == person.id } }
                })) {
                    HStack(spacing: 6) {
                        Avatar(name: person.name, size: 18, url: person.avatarURL)
                        Text(person.id == store.me.id ? "Me" : person.name).lineLimit(1)
                    }
                }.toggleStyle(.checkbox)
            }
        }
        .padding(12).frame(width: 240)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !query.isEmpty else { found = picked.filter { $0.id != store.me.id }; return }
            found = (try? await store.searchPeople(query)) ?? []
        }
    }
}

/// Conversations to search in: the picked ones, then the rest by recent activity, narrowed by name.
private struct ConversationPicker: View {
    let store: ChatStore
    @Binding var picked: [ConversationID]
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Conversation name", text: $query).textFieldStyle(.roundedBorder)
            ForEach(shown) { room in
                Toggle(isOn: Binding(get: { picked.contains(room.id) }, set: { on in
                    if on { picked.append(room.id) } else { picked.removeAll { $0 == room.id } }
                })) {
                    HStack(spacing: 6) {
                        Avatar(name: room.name, space: room.kind == .space, size: 18, url: room.avatarURL, emoji: room.emoji)
                        Text(room.name).lineLimit(1).truncationMode(.tail)
                    }
                }.toggleStyle(.checkbox)
            }
        }
        .padding(12).frame(width: 260)
    }
    private var shown: [Conversation] {
        let matching = store.conversations.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }
        return Array((matching.filter { picked.contains($0.id) } + matching.filter { !picked.contains($0.id) }).prefix(8))
    }
}

/// A custom date range, whole days: the end day counts, as in Google Chat.
private struct DateRangeSheet: View {
    let done: (Range<Date>?) -> Void
    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var end = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Range").font(.headline)
            DatePicker("From", selection: $start, in: ...end, displayedComponents: .date)
            DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let calendar = Calendar.current, from = calendar.startOfDay(for: start)
                    let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
                    done(from..<to)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 300)
    }
}

extension ToolbarContent {
    /// A title is not a control: no glass capsule around it (macOS 26 gives every toolbar item one), as Messages shows the name.
    @ToolbarContentBuilder func titleWithoutGlass() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}
extension CustomizableToolbarContent {
    /// As above, for an item of a customizable toolbar.
    @ToolbarContentBuilder func titleWithoutGlass() -> some CustomizableToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// The window a view is in, held weakly.
final class WindowRef { weak var window: NSWindow? }
final class WidthRef { var value: CGFloat = 0 }
/// Records its view's window in `ref` once it is in one, hands it to `appeared`, and keeps its title at `title` when set.
struct WindowReader: NSViewRepresentable {
    let ref: WindowRef
    var title: String? = nil
    var appeared: ((NSWindow) -> Void)? = nil
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
        init(ref: WindowRef, appeared: ((NSWindow) -> Void)?) { self.ref = ref; self.appeared = appeared; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); ref.window = window
            watch = nil
            guard let window else { return }
            if let title { window.title = title }   // before it joins a tab group, so the tab shows the name
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
        window.tabbingIdentifier = identifier   // Window ▸ Merge All Windows joins conversation windows either way
        guard asTab, window.tabbedWindows == nil,
              let host = windows.first(where: { $0 !== window && $0.isVisible && $0.tabbingIdentifier == identifier }) else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// The sidebar's Show all / Show less icon, as web Chat draws it: chevrons pointing apart to show more, together to show
/// less. SF Symbols has only the first, so the second is two chevrons stacked.
extension ChatView {
    /// Spaces, DMs and group DMs have threads, as in Google Chat; a DM with an app doesn't.
    static func offersThreads(_ room: Conversation) -> Bool { room.app == nil }
    /// The empty composer's prompt, as Google Chat's: Ask Gemini asks Gemini, and with history off it says so.
    static func composerPrompt(_ conversation: Conversation, thread: ThreadID? = nil) -> String {
        if conversation.app == .gemini { return thread == nil ? "Ask Gemini…" : "Reply" }   // a session's thread replies
        return conversation.historyOff == true ? "History is off" : "Message"
    }
    static func invitationsTitle(_ count: Int) -> String { count == 1 ? "1 space invitation" : "\(count) space invitations" }
}

struct ShowAllIcon: View {
    let open: Bool
    var body: some View {
        if open {
            VStack(spacing: -3) { Image(systemName: "chevron.down"); Image(systemName: "chevron.up") }
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        } else {
            Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
        }
    }
}

/// A file dropped on the conversation: one from Finder, used where it is, or a promised one (Photos, a screenshot's
/// thumbnail, the timeline's own attachments), received into a temporary copy as the composer receives it.
struct DroppedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in DroppedFile(url: url) })
        FileRepresentation(importedContentType: .item) { received in
            // SwiftUI deletes the received file once this returns: keep a copy.
            let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return DroppedFile(url: copy)
        }
    }
}

/// Google Chat's Create a space: a name and, if wanted, an emoji. The space opens once Google has made it.
struct NewSpaceSheet: View {
    let store: ChatStore
    @State private var name = ""
    @State private var emoji: String?
    @State private var pickingEmoji = false
    @State private var working = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Space").font(.headline)
            HStack(spacing: 10) {
                Button { pickingEmoji = true } label: {
                    Avatar(name: name.isEmpty ? "?" : name, space: true, size: 36, emoji: emoji)
                }.buttonStyle(.plain).help("Choose an emoji")
                    .popover(isPresented: $pickingEmoji) {
                        EmojiPicker(frequent: EmojiUsage().top(EmojiPicker.columns), pick: { emoji = $0; pickingEmoji = false },
                                    close: { pickingEmoji = false })
                    }
                TextField("Space name", text: $name).textFieldStyle(.roundedBorder)
                    .onChange(of: name) { if name.count > 128 { name = String(name.prefix(128)) } }   // Google Chat's limit
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    working = true; problem = nil
                    Task {
                        defer { working = false }
                        do { try await store.createSpace(name: name, emoji: emoji); dismiss() } catch { problem = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(18).frame(width: 380)
    }
}
