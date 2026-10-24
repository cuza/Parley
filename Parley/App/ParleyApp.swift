import AppIntents
import ParleyData
import ParleyDomain
import SwiftUI

@main
struct ParleyApp: App {
    @State private var store: ChatStore
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var signIn: SignInFlow
    private let authorizer: WebSessionAuthorizer
    private let webSignIn: WebViewSignIn
    private let updates: Updates
    private let spotlight: ConversationSpotlight?  // the signed-in account's conversations; none for demo and test runs
    /// Conversation and thread windows come back at launch, except in test runs: a window left by an earlier test would
    /// cover the main window the next test clicks in.
    private let restoresWindows: SceneRestorationBehavior
    init() {
        AppearanceMode.apply()
        let authorizer = WebSessionAuthorizer()
        self.authorizer = authorizer
        let (store, live, restoresWindows) = Self.launchStore(authorizer: authorizer)
        self.restoresWindows = restoresWindows
        store.onBadge = { NSApplication.shared.dockTile.badgeLabel = $0 }
        store.undoManager = { NSApplication.shared.keyWindow?.undoManager }  // Edit ▸ Undo in the window the user acted in
        store.clearDiskCaches = {
            for folder in [AttachmentFiles.defaultFolder, ImageCache.directory].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await store.appBecameActive() }
        }
        _store = State(initialValue: store)
        spotlight = live ? ConversationSpotlight() : nil
        if live, #available(macOS 27, *) {
            store.sent = { [weak store] id in
                guard let store, let room = store.rooms.conversations.first(where: { $0.id == id }) else { return }
                SiriDonation.donate(room, me: store.me.id)
            }
        }
        AppDependencyManager.shared.add(dependency: store)  // what Shortcuts' and Siri's actions act on
        let webSignIn = WebViewSignIn()
        self.webSignIn = webSignIn
        let signIn = SignInFlow(browser: webSignIn, importer: authorizer)
        signIn.onSignedIn = {
            NSApplication.shared.activate()
            await store.start()
        }
        if live {
            // Keep the session alive as the Chat website does: renew it silently when Google ends it, and every few hours.
            signIn.renewer = SessionRenewer()
            store.onSessionLost = { if await signIn.renewSilently() { await store.start() } }
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(6 * 3600))
                    if store.connection == .connected { _ = await signIn.renewSilently() }
                }
            }
        }
        _signIn = State(initialValue: signIn)
        NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { event in
            guard let step = HistoryStep(event) else { return event }
            Task { step == .forward ? await store.goForward() : await store.goBack() }
            return nil
        }
        // Since macOS 13 tables estimate unmeasured row heights, which moves rows when older pages land above;
        // MessageTable caches real heights, so opt out as Apple's AppKit release notes describe.
        UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
        #if DEBUG
            let debug = true
        #else
            let debug = false
        #endif
        updates = Updates(start: Updates.shouldStart(live: live, debug: debug))
    }
    var body: some Scene {
        Window("Parley", id: "main") {
            ChatView()
                .environment(store)
                .environment(signIn)
                .modifier(WebSignInPresenter(flow: signIn, web: webSignIn))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    signIn.cancel()
                    store.flush()
                }
                // Leaving the composer, as Google Chat's web client saves its draft when you click away.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    store.saveDrafts()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                    store.saveDrafts()
                }
                .onChange(of: store.rooms.conversations, initial: true) { _, rooms in
                    Task { await spotlight?.update(rooms, me: store.me.id) }
                }
                .onAppear {
                    appDelegate.beforeQuit = { store.saveDrafts() }
                    appDelegate.openURL = { url in
                        if let shared = Shared(link: url) {
                            store.sharing = shared
                        } else {
                            Task { await store.open(url: url) }
                        }
                    }
                    appDelegate.shareService.received = { store.sharing = $0 }
                    appDelegate.dockMenu = {
                        DockMenu.make(
                            store.dockConversations,
                            open: { id in
                                NSApp.activate()
                                Task { await store.select(id) }
                            },
                            markAllRead: { Task { await store.markAllRead() } })
                    }
                }
        }
        .defaultSize(width: 1000, height: 650)
        .commands {
            SidebarCommands()  // View ▸ Show/Hide Sidebar (⌃⌘S): the sidebar can always come back, whatever the toolbar shows
            ToolbarCommands()  // View ▸ Show/Hide Toolbar and Customize Toolbar…, as Mail has them
            CommandGroup(after: .appInfo) { CheckForUpdatesItem(updates: updates) }
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.newChatRequests += 1 }.keyboardShortcut("n")
                Button("New Space…") { store.newSpaceRequests += 1 }.keyboardShortcut(
                    "n", modifiers: [.command, .shift])
                MeetLinkMenuItem().environment(store)
            }
            CommandGroup(replacing: .help) { DiagnosticsMenuItem() }
            ChatMenuCommands(store: store)
        }
        WindowGroup(for: ConversationID.self) { $id in
            // The tab bar's + opens one without a conversation: it offers the palette, and the pick fills it.
            if let id = id {
                ChatView(fixedConversation: id).environment(store).environment(signIn)
            } else {
                NewTab { id = $0 }.environment(store)
            }
        }
        .defaultSize(width: 520, height: 680)
        .windowResizability(.contentMinSize)  // no narrower than the timeline and its open side pane
        .restorationBehavior(restoresWindows)
        WindowGroup(for: ThreadRef.self) { $ref in
            if let ref { ThreadWindow(ref: ref).environment(store).environment(signIn) }
        }
        .defaultSize(width: 420, height: 640)
        .windowResizability(.contentMinSize)
        .restorationBehavior(restoresWindows)
        Settings { SettingsView().environment(store).environment(signIn) }
        // Opened from Settings ▸ Advanced and Help ▸ Report a Problem, not the Window menu.
        Window("Connection Diagnostics", id: "connection-diagnostics") {
            ConnectionDiagnosticsView(model: ConnectionDiagnostics(authorizer: authorizer)).environment(store)
                .environment(signIn)
        }
        .defaultSize(width: 560, height: 720)
        .commandsRemoved()
    }
}

extension ConnectionDiagnostics {
    /// The app's own authorizer, so a check that finds the session gone signs the app out too.
    convenience init(authorizer: WebSessionAuthorizer) {
        self.init(vault: KeychainSessionVault(), probe: { try await DynamiteReadProbe(authorizer: authorizer).run() })
    }
}
