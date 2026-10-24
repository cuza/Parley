import AppIntents
import AppKit
import ParleyDomain
import SwiftUI

/// A window's content: the sidebar and the detail column in the main window, or one conversation in its own window.
struct ChatView: View {
    @Environment(ChatStore.self) var store
    var fixedConversation: ConversationID?
    init(fixedConversation: ConversationID? = nil) {
        self.fixedConversation = fixedConversation
        _columns = State(initialValue: Self.initialColumns(fixedConversation: fixedConversation))
    }
    /// A conversation in its own window opens without the sidebar: there is nothing to choose there.
    static func initialColumns(fixedConversation: ConversationID?) -> NavigationSplitViewVisibility {
        fixedConversation == nil ? .all : .detailOnly
    }
    @State var switcher = false
    @State var composing = false  // the palette as New Chat
    @State var finding: MessageSearchPanel.Request?
    @State private var creatingSpace = false
    @State private var columns: NavigationSplitViewVisibility
    @State private var sidebarAutoHidden = false  // hidden by us for a narrow window: it comes back when there is room
    @State private var width = WidthRef()  // read only by actions, so kept out of state: it changes every frame of a resize
    @State var sidebarWidth: CGFloat = 230  // as last measured while shown
    @State private var hostWindow = WindowRef()  // this view's own window
    @State var leaving: Conversation?  // asks before leaving
    @State var blocking: BlockSheet.Target?
    @State var deletingSection: SidebarSection?  // asks before deleting a section
    @State var naming: SectionNaming?  // New Section (with the conversation that goes in it) or Rename
    @State var sectionName = ""
    struct SectionNaming: Identifiable {
        var id: String { section?.id ?? "new-\(moving ?? "")" }
        var section: SidebarSection?
        var moving: ConversationID?
    }
    @AppStorage("collapsedSidebarSections") var collapsedSections = ""  // titles, one per line
    @AppStorage(SidebarLimit.enabledKey) var limitSections = false
    @AppStorage(SidebarLimit.countKey) var sectionLimit = 10
    @AppStorage(SidebarLimit.expandedKey) var expandedSections = ""  // "Show all" sections' titles, one per line
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) var openURL
    @Environment(SignInFlow.self) var signIn: SignInFlow?
    /// This window's side pane: a conversation window has its own, so a thread opened there stays there.
    var pane: SidePane { store.navigation.pane(fixedConversation) }
    var paneOpen: Bool { Self.paneShown(pane, room: room) }
    var room: Conversation? {
        store.rooms.conversations.first { $0.id == (fixedConversation ?? store.navigation.selectedID) }
    }
    /// ⌘F: search what's open, the conversation as the "said in" filter, or everywhere from Home and the other shortcuts.
    func find() { finding = .init(scope: store.navigation.shortcut == nil ? room : nil) }
    /// A conversation's own window: titled with its name, which its tab and the Window menu show, and tabbed with the
    /// conversation window already open.
    private func tabbed(_ window: NSWindow) {
        if fixedConversation != nil { ConversationTabs.join(window, among: NSApp.windows) }
    }
    private var windowTitle: String? { fixedConversation == nil ? nil : room?.name }
    /// ⌘F's panel, or Search Messages' from Shortcuts, which opens in the main window only.
    private var findingSheet: Binding<MessageSearchPanel.Request?> {
        Binding(
            get: {
                finding
                    ?? (fixedConversation == nil
                        ? store.searchRequest.map { MessageSearchPanel.Request(id: $0.id, scope: nil, query: $0.query) }
                        : nil)
            },
            set: {
                finding = $0
                if $0 == nil { store.searchRequest = nil }
            })
    }
    /// Send to Parley picks its conversation in the main window only.
    private var sharing: Binding<Shared?> {
        Binding(get: { fixedConversation == nil ? store.sharing : nil }, set: { store.sharing = $0 })
    }
    /// What this window's menu items do.
    var commands: ChatCommands {
        ChatCommands(
            find: fixedConversation == nil ? { find() } : nil,
            jump: { switcher = true },
            info: { if room != nil { store.toggleInfo(window: fixedConversation) } },
            editLast: {
                if let room, let last = store.timeline(room.id).last(where: { $0.sender.id == store.me.id }) {
                    store.edit(last)
                }
            },
            unread: { forward in
                if let room = Conversation.nextUnread(
                    after: store.navigation.selectedID, in: store.rooms.conversations, forward: forward)
                {
                    Task { await store.select(room.id) }
                }
            },
            room: shown,
            threads: shown.flatMap {
                Self.offersThreads($0) ? { Task { await store.toggleThreads(window: fixedConversation) } } : nil
            },
            threadsShown: pane.threads && pane.thread == nil,
            openInWindow: shown.flatMap { room in fixedConversation == nil ? { openWindow(value: room.id) } : nil },
            newSection: shown.map { room in
                {
                    sectionName = ""
                    naming = SectionNaming(moving: room.id)
                }
            },
            leave: shown.flatMap { room in room.kind != .direct ? { leaving = room } : nil },
            block: shown.flatMap { room in
                if room.kind == .space { return { blocking = .space(room.id, name: room.name) } }
                guard room.kind == .direct, room.app == nil, let partner = store.partner(in: room) else { return nil }
                return { blocking = .person(partner, name: room.name) }
            },
            attach: shown.map { room in
                {
                    Self.chooseFiles { urls in
                        // Into the composer being typed in (a thread's, say), else the conversation's own.
                        if let composer = ComposerFocus.shared.composer, let attach = composer.attach {
                            attach(urls)
                        } else {
                            store.attach(urls, conversation: room.id, thread: nil)
                        }
                    }
                }
            })
    }
    /// The conversation on screen, for the menus: none while Home or another shortcut is.
    private var shown: Conversation? { fixedConversation != nil || store.navigation.shortcut == nil ? room : nil }
    /// File ▸ Attach Files… and the paperclip: the open panel, as Mail's.
    static func chooseFiles(_ chosen: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.begin { response in if response == .OK { chosen(panel.urls) } }
    }
    private var handoff: URL? {
        Self.handoffURL(room, shortcut: fixedConversation == nil ? store.navigation.shortcut : nil)
    }
    /// What Handoff offers: the conversation on screen; Home and the other shortcuts have no web page of their own.
    static func handoffURL(_ room: Conversation?, shortcut: Shortcut?) -> URL? {
        guard shortcut == nil, let room else { return nil }
        return ChatLink.url(room.id)
    }
    /// Hides or brings back the sidebar as the window's width allows, as `sidebar(width:…)` decides.
    private func fitSidebar() {
        let next = Self.sidebar(
            width: width.value, paneOpen: paneOpen, sidebarWidth: sidebarWidth,
            visible: columns != .detailOnly, autoHidden: sidebarAutoHidden)
        if (columns != .detailOnly) != next.visible { columns = next.visible ? .all : .detailOnly }
        if sidebarAutoHidden != next.autoHidden { sidebarAutoHidden = next.autoHidden }
    }
    var body: some View {
        @Bindable var store = store
        Group {
            // A conversation's own window is just that conversation: no split view, so no sidebar or its button.
            if fixedConversation != nil {
                NavigationStack { detail }
            }
            // The detail's minimum stops a dragged sidebar from squeezing the timeline and pane off the window's edge.
            else {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } detail: {
                    detail.navigationSplitViewColumnWidth(
                        min: Self.minWidth(paneOpen: paneOpen, sidebar: 0), ideal: 700)
                }
            }
        }
        .frame(minWidth: Self.minWidth(paneOpen: paneOpen, sidebar: 0), minHeight: 480)
        .onChange(of: paneOpen) { _, open in
            guard open else { return }
            let sidebar = Self.shownSidebar(
                fixedConversation: fixedConversation, columns: columns, measured: sidebarWidth)
            Self.makeRoom(Self.widthForPane(window: width.value, sidebar: sidebar), in: hostWindow.window)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width.value = $0
            fitSidebar()
        }
        .background(WindowReader(ref: hostWindow, title: windowTitle, appeared: tabbed))
        .onChange(of: paneOpen) { fitSidebar() }
        .onChange(of: columns) { _, shown in
            // Shown by the user in a window too narrow for it: widen the window rather than clip.
            if shown != .detailOnly {
                sidebarAutoHidden = false
                Self.makeRoom(Self.minWidth(paneOpen: paneOpen, sidebar: sidebarWidth), in: hostWindow.window)
            }
        }
        .sheet(isPresented: $switcher) { ConversationPalette() }
        .sheet(isPresented: $composing) { ConversationPalette(newChat: true) }
        .sheet(item: $store.forwarding) { message in
            ConversationPalette(then: { store.forward(message, to: $0) })
        }
        .sheet(item: findingSheet) { MessageSearchPanel(scope: $0.scope, query: $0.query) }
        .sheet(item: sharing) { shared in
            ConversationPalette(then: { store.share(shared, to: $0) }, thenPrompt: "Send to a conversation or person")
        }
        // Handoff: the open conversation as a web page, as a browser offers it; Google Chat's iPhone and iPad app opens its links.
        .userActivity(NSUserActivityTypeBrowsingWeb, isActive: handoff != nil) { activity in
            activity.webpageURL = handoff
            activity.title = room?.name
            // Siri's on-screen awareness: the conversation in front, as the entity its actions take.
            if #available(macOS 15.2, *), let room {
                activity.appEntityIdentifier = EntityIdentifier(
                    for: ConversationEntity.self, identifier: room.id.rawValue)
            }
        }
        .onChange(of: store.newChatRequests) { if fixedConversation == nil { composing = true } }
        .onChange(of: store.newSpaceRequests) {
            if fixedConversation == nil {
                composing = false
                creatingSpace = true
            }
        }
        .sheet(isPresented: $creatingSpace) { NewSpaceSheet() }
        .sheet(item: $blocking) { BlockSheet(target: $0) }
        .alert(naming?.section == nil ? "New Section" : "Rename Section", isPresented: Binding(isPresent: $naming)) {
            TextField("Section name", text: $sectionName)
            Button(naming?.section == nil ? "Create" : "Rename") {
                let request = naming
                let name = sectionName
                Task {
                    if let section = request?.section {
                        await store.renameSection(section, to: name)
                    } else {
                        await store.createSection(name, moving: request?.moving)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .focusedSceneValue(\.chatCommands, commands)
        .background {  // ⌘1 to ⌘9 stay out of the menus, as tabs' do in Safari; the main window's only
            if fixedConversation == nil {
                ForEach(1...9, id: \.self) { number in
                    Color.clear.hiddenShortcut(KeyEquivalent(Character(String(number)))) {
                        if let room = Conversation.atShortcut(
                            number, in: store.rooms.conversations, limit: sectionLimitArgs.limit,
                            expanded: sectionLimitArgs.expanded, selected: store.navigation.selectedID,
                            custom: store.rooms.sections)
                        {
                            Task { await store.select(room.id) }
                        }
                    }
                }
            }
        }
        .overlay {
            if store.needsSignIn {
                if let signIn {
                    WelcomeView(flow: signIn)
                } else {
                    ContentUnavailableView(
                        "Signed out of Google Chat", systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                }
            }
        }
        .toolbar(store.needsSignIn ? .hidden : .automatic, for: .windowToolbar)
        // A frosted toolbar across the window, over the timeline and the side pane alike, instead of a clear one that
        // content (the wallpaper, a scrolled pane) shows through.
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .confirmationDialog("Leave “\(leaving?.name ?? "")”?", isPresented: Binding(isPresent: $leaving)) {
            Button("Leave", role: .destructive) { if let room = leaving { Task { await store.leave(room.id) } } }
        } message: {
            Text("It leaves your sidebar. You can be added again later.")
        }
        .confirmationDialog(
            "Delete the section “\(deletingSection?.name ?? "")”?", isPresented: Binding(isPresent: $deletingSection)
        ) {
            Button("Delete Section", role: .destructive) {
                if let section = deletingSection { Task { await store.deleteSection(section) } }
            }
        } message: {
            Text("Its conversations go back to their usual sections.")
        }
        // An app's dialog, over the window that shows its conversation.
        .sheet(
            isPresented: Binding(
                get: {
                    store.dialog.map { store.navigation.window(for: $0.conversation) == fixedConversation } ?? false
                },
                set: { if !$0 { Task { await store.cancelDialog() } } })
        ) {
            if let open = store.dialog {
                DialogSheet(
                    open: open, submit: { await store.submitDialog(action: $0, inputs: $1) },
                    cancel: { Task { await store.cancelDialog() } })
            }
        }
        .overlay(alignment: .bottom) {  // an app's note, for a moment ("Poll started.")
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
        .onAppear { if let fixedConversation { store.navigation.windowOpened(fixedConversation) } }
        .onDisappear { if let fixedConversation { store.navigation.windowClosed(fixedConversation) } }
        .alert("Couldn’t finish that", isPresented: Binding(isPresent: $store.error)) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .task(id: fixedConversation.flatMap(store.hasConversation)) {
            if let fixedConversation {  // a restored window: loads, or closes when the conversation isn't this account's
                switch store.hasConversation(fixedConversation) {
                case true?: await store.load(fixedConversation)
                case false?: dismissWindow()
                case nil: break
                }
            } else {
                // Not awaited: the permission prompt waits for the user, and until then nothing would connect or ask to sign in.
                if store.notifier != nil, NotificationSettings.current.enabled {
                    Task { await NotificationSettings.requestAuthorization() }
                }
                await store.start()
            }
        }
    }
    /// Spaces, DMs and group DMs have threads, as in Google Chat; a DM with an app doesn't.
    static func offersThreads(_ room: Conversation) -> Bool { room.app == nil }
}
extension EnvironmentValues {
    /// The window a view is in, for its side pane: nil in the main window, else the conversation a conversation window shows.
    @Entry var paneWindow: ConversationID?
}
