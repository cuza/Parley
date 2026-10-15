import AppKit
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

@MainActor @Observable
final class ChatStore {
    var conversations: [Conversation] = []
    /// Hidden from my sidebar (`Conversation.hidden`), for Settings ▸ Hidden conversations.
    var hidden: [Conversation] = []
    var messages: [Message] = [] { didSet { timelines = [:] } }
    /// Sorted timelines by draft key, kept until `messages` changes: a timeline view reads its messages several times
    /// per update, and filtering and sorting every loaded message each time showed up in profiles.
    @ObservationIgnored private var timelines: [String: [Message]] = [:]
    var selectedID: ConversationID? { didSet { if selectedID != oldValue { saveDrafts() } } }   // leaving a composer saves its draft
    var drafts: [String: String] = [:] {
        didSet { let scopes = Set(drafts.filter { !Self.blank($0.value) }.keys); if scopes != draftedScopes { draftedScopes = scopes } }
    }
    /// The draft keys whose composer holds text. It changes only when a draft starts or is cleared, so a view showing
    /// "1 draft" reads this, not `drafts`, and doesn't update on every keystroke.
    private(set) var draftedScopes: Set<String> = []
    var draftFormatting: [String: [TextStyleRange]] = [:]   // per draft key, UTF-16 ranges into the draft text
    var draftAttachments: [String: [Attachment]] = [:]   // per draft key, local files to upload on send (not cached across launches)
    var connection: ConnectionState = .offline {
        // A session that ends while in use is first renewed silently (see `onSessionLost`); the banner shows meanwhile.
        didSet { if connection == .signedOut, oldValue != .signedOut, !me.id.isEmpty { Task { await onSessionLost() } } }
    }
    @ObservationIgnored var onSessionLost: @MainActor () async -> Void = {}
    var error: String?
    // For Connection Diagnostics.
    private(set) var connectedSince: Date?
    private(set) var lastEventAt: Date?   // the last event from Google, not counting connection changes
    private(set) var reconnects = 0
    var threadID: ThreadID? { didSet { if threadID != oldValue { saveDrafts() } } }
    var info = false   // the conversation info panel, which shares the inspector with the thread
    /// A space's Threads list in the side pane; an open thread shows over it, and closing the thread goes back to it.
    var threadsShown = false
    private(set) var threadSummaries: [ConversationID: [ThreadSummary]] = [:]
    var editing: [String: MessageID] = [:]   // per draft key: the sent message that composer is editing
    /// Per draft key being edited: the draft the edit borrowed the composer from, given back when the edit ends.
    private var heldDrafts: [String: (text: String, formatting: [TextStyleRange]?)] = [:]
    var quoting: [String: QuotedMessage] = [:]   // per draft key: the message the next send quotes (not cached across launches)
    var searchResults: [Message] = []
    /// The sidebar shortcut shown instead of a conversation; nil while a conversation shows.
    var shortcut: Shortcut? { didSet { if shortcut != oldValue { saveDrafts() } } }
    private var shortcutLists: [Shortcut: [Message]] = [:]
    var homeUnreadOnly = false   // Home's filters, kept for the session
    var homeThreadsOnly = false
    private(set) var homeThreads: [HomeThread] = []   // Home's thread rows, from the backend's last conversation list
    @ObservationIgnored private var shortcutCursors: [Shortcut: String] = [:]
    /// A message just jumped to, outlined in the timeline; it fades after `highlightDuration`, as Telegram flashes it.
    var highlightedID: MessageID? {
        didSet {
            highlightFade?.cancel()
            guard highlightedID != nil else { return }
            highlightFade = Task { [weak self, highlightDuration] in
                try? await Task.sleep(for: highlightDuration)
                guard !Task.isCancelled else { return }
                self?.highlightedID = nil
            }
        }
    }
    @ObservationIgnored var highlightDuration: Duration = .seconds(3)
    /// Voice messages whose whole transcript shows; the rest show one line, as Google Chat does.
    private(set) var openTranscripts: Set<MessageID> = []
    func toggleTranscript(_ id: MessageID) { if openTranscripts.remove(id) == nil { openTranscripts.insert(id) } }
    @ObservationIgnored private var highlightFade: Task<Void, Never>?
    var hasMore: Set<String> = []
    /// The info panel's shared items from the server, per `sharedKey`; absent until loaded, or if the server refused.
    private(set) var shared: [String: [SharedContent.Item]] = [:]
    private(set) var sharedMore: Set<String> = []
    private(set) var members: [ConversationID: [Person]] = [:]   // per conversation, from `ChatBackend.members(of:)`
    private(set) var permissions: [ConversationID: ConversationPermissions] = [:]   // what I may change, once the server said
    @ObservationIgnored private var memberLoads: Set<ConversationID> = []
    /// The organisation's custom emoji, for the picker and `:shortcode` suggestions; see `loadCustomEmoji`.
    private(set) var customEmoji: [CustomEmoji] = []
    @ObservationIgnored private var customEmojiLoad: Task<Void, Never>?
    /// The conversations' apps' slash commands found so far, for the composer's "/" list; see `loadSlashCommands`.
    private(set) var slashCommands: [ConversationID: [SlashCommand]] = [:]
    @ObservationIgnored private var slashQueries: [ConversationID: Set<String>] = [:]
    @ObservationIgnored private var reactors: [MessageID: [Reaction: [Person]]] = [:]   // see `reactorsLine`
    private(set) var loading: Set<String> = []
    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let cache: LaunchCache?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var cachedAccountID: String?
    @ObservationIgnored private var loaded: Set<String> = []
    @ObservationIgnored private var searchGeneration = 0
    private(set) var me = Person(id: "", name: "")
    // Typing, presence and read receipts.
    private(set) var typing: [String: [String: Date]] = [:]   // draft key → typist → local arrival
    /// An agent at work by draft key, shown in that composer's typing line: in the asker's thread and in the conversation.
    private(set) var activities: [String: Activity] = [:]
    struct Activity: Equatable { var person: PersonID; var label: String; var at: Date }
    private(set) var presence: [String: Presence] = [:]
    private(set) var statuses: [String: String] = [:]          // custom status text
    /// Mine, as the server last said; `OwnStatus.current(at:)` drops what has expired since.
    private(set) var ownStatus = OwnStatus()
    private(set) var readReceipts: [ConversationID: [String: Date]] = [:]   // reader → read up to
    @ObservationIgnored private var receiptsOff: Set<ConversationID> = []
    // Threads seen this session (loaded, pushed, or labelled while connected) plus Home's, which are the server's followed ones;
    // a reply in any other thread re-reads Home's (checkFollowed).
    private var followed: Set<ThreadID> = []   // observed: the thread pane's bell shows it
    @ObservationIgnored private var presenceFetched: [String: Date] = [:]
    @ObservationIgnored private var notifiedReactions: Set<String> = []   // message#person#emoji already announced
    @ObservationIgnored private var typingSent: [String: Date] = [:]
    @ObservationIgnored private var typingRefused: Set<String> = []   // composers where Google answered 403; not retried this session
    @ObservationIgnored private var watching: Set<ConversationID>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    /// The clock typing, presence and throttles run on; tests replace it.
    @ObservationIgnored var now: () -> Date = { .now }
    static let typingTimeout: TimeInterval = 8, typingInterval: TimeInterval = 5, presenceTTL: TimeInterval = 60
    static let unreadWindow: TimeInterval = 120   // matches NotificationPolicy's age guard
    /// Whether the user can see the window; read receipts follow it.
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { NSApplication.shared.isActive }
    /// Banners for pushed messages; nil (tests, previews) posts nothing.
    @ObservationIgnored var notifier: (any Notifier)?
    @ObservationIgnored var notificationSettings: @MainActor () -> NotificationSettings = { .current }
    // Server drafts: each composer's draft saved to Google too, so it follows the user to web and phone (see `syncDraft`).
    private(set) var serverDrafts: [String: ServerDraft] = [:]   // per draft key: Google's copy, as last saved or heard of
    /// Messages Google sends later, soonest first: scheduled from a composer here or elsewhere (see `schedule`).
    private(set) var scheduled: [ServerDraft] = []
    @ObservationIgnored private var draftEdits: [String: Date] = [:]   // draft keys typed in since their last save, and when
    @ObservationIgnored private var draftsListed = false
    @ObservationIgnored private var draftListing: Task<Bool, Never>?
    @ObservationIgnored private var draftWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftTimers: [String: Task<Void, Never>] = [:]
    /// Drafts a send used up (Google drops them): a late echo of one never refills a composer.
    @ObservationIgnored private var spentDrafts: Set<String> = []
    /// Sends per draft key: a save that started before the latest send finishes as a leftover, which is deleted.
    @ObservationIgnored private var draftSends: [String: Int] = [:]
    /// Google Chat's web client creates a draft a few seconds into a pause and updates it when the user leaves the composer;
    /// the idle save is a safety net. Tests shorten both.
    @ObservationIgnored var draftPause: Duration = .seconds(3)
    @ObservationIgnored var draftIdle: Duration = .seconds(30)

    init(backend: any ChatBackend, cache: LaunchCache? = nil) {
        self.backend = backend; self.cache = cache
        if let snapshot = cache?.load() {
            cachedAccountID = snapshot.accountID
            conversations = snapshot.conversations; messages = snapshot.messages
            selectedID = snapshot.selectedID; drafts = snapshot.drafts; draftFormatting = snapshot.draftFormatting
            draftEdits = snapshot.draftEdits; serverDrafts = snapshot.serverDrafts; homeThreads = snapshot.homeThreads
        }
    }
    /// No session, or it was lost before this launch connected: the welcome screen.
    var needsSignIn: Bool { connection == .signedOut && me.id.isEmpty }
    /// The session ended while the app was in use: a banner over the conversations, which stay.
    var sessionExpired: Bool { connection == .signedOut && !me.id.isEmpty }
    /// Another account connected: nothing of the previous one may show, be sent, or be cached. Clears every property in
    /// `accountState`; a test holds each stored property to one of the two lists.
    private func forgetAccount() {
        draftListing?.cancel()
        for task in [customEmojiLoad, followCheck].compactMap({ $0 }) + Array(draftTimers.values) + Array(draftWrites.values) + Array(pageLoads.values) { task.cancel() }
        draftListing = nil; customEmojiLoad = nil; followCheck = nil; draftTimers = [:]; draftWrites = [:]; pageLoads = [:]
        serverDrafts = [:]; scheduled = []; pinned = [:]; draftEdits = [:]; draftsListed = false; spentDrafts = []; draftSends = [:]
        conversations = []; hidden = []; homeThreads = []; messages = []; timelines = [:]; selectedID = nil; drafts = [:]; draftedScopes = []
        draftFormatting = [:]; draftAttachments = [:]; quoting = [:]; editing = [:]; heldDrafts = [:]
        searchResults = []; shortcut = nil; shortcutLists = [:]; shortcutCursors = [:]; hasMore = []; loaded = []; loading = []
        threadID = nil; info = false; threadsShown = false; threadSummaries = [:]; highlightedID = nil; openTranscripts = []
        members = [:]; memberLoads = []; permissions = [:]; roles = [:]; shared = [:]; sharedMore = []; customEmoji = []
        slashCommands = [:]; slashQueries = [:]; reactors = [:]; notifiedReactions = []
        typing = [:]; activities = [:]; presence = [:]; statuses = [:]; ownStatus = OwnStatus(); readReceipts = [:]; receiptsOff = []
        followed = []; presenceFetched = [:]; watching = nil; typingSent = [:]; typingRefused = []; awaitingFollow = []
        detached = []; windowEnds = [:]; newerLoads = []; listedOnce = false; backPlaces = []; forwardPlaces = []
        dialog = nil; forwarding = nil; heldUnread = []; sections = []; blockedPeople = []; dndSchedules = nil
        invitations = []; invitationsFetched = nil
    }
    /// What `forgetAccount` clears when another account connects.
    static let accountState: Set<String> = [
        "draftListing", "customEmojiLoad", "followCheck", "draftTimers", "draftWrites", "pageLoads",
        "serverDrafts", "scheduled", "pinned", "draftEdits", "draftsListed", "spentDrafts", "draftSends",
        "conversations", "hidden", "homeThreads", "messages", "timelines", "selectedID", "drafts", "draftedScopes",
        "draftFormatting", "draftAttachments", "quoting", "editing", "heldDrafts",
        "searchResults", "shortcut", "shortcutLists", "shortcutCursors", "hasMore", "loaded", "loading",
        "threadID", "info", "threadsShown", "threadSummaries", "highlightedID", "openTranscripts",
        "members", "memberLoads", "permissions", "roles", "shared", "sharedMore", "customEmoji",
        "slashCommands", "slashQueries", "reactors", "notifiedReactions",
        "typing", "activities", "presence", "statuses", "ownStatus", "readReceipts", "receiptsOff",
        "followed", "presenceFetched", "watching", "typingSent", "typingRefused", "awaitingFollow",
        "detached", "windowEnds", "newerLoads", "listedOnce", "backPlaces", "forwardPlaces",
        "dialog", "forwarding", "heldUnread", "sections", "blockedPeople", "dndSchedules",
        "invitations", "invitationsFetched",
    ]
    /// What stays across accounts: the app's wiring, settings, timers and the connection, and requests the user made
    /// before the switch (a link to open, content to share, a search to run).
    static let appState: Set<String> = [
        "backend", "cache", "cachedAccountID", "me", "connection", "onSessionLost", "error", "connectedSince", "lastEventAt",
        "reconnects", "homeUnreadOnly", "homeThreadsOnly", "highlightDuration", "highlightFade", "eventTask", "cacheTask",
        "searchGeneration", "sweepTask", "now", "isAppActive", "notifier", "notificationSettings", "draftPause", "draftIdle",
        "waitingLinks", "resyncTask", "resyncAgain", "followAsked", "followRecheck", "toast", "toastDuration", "toastFade", "openURL", "defaults", "sent",
        "download", "newChatRequests", "newSpaceRequests", "sharing", "searchRequest",
    ]
    /// After the user signs out; cached conversations and drafts stay for the next sign-in.
    func signedOut() {
        me = Person(id: "", name: "")
        connection = .signedOut
    }
    /// Shows a failure to the user. Cancellation is not one: the work was superseded or no longer wanted.
    /// A lost session is not one either: it shows as the session-expired banner, which offers to sign in again.
    func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || endedSession(error) { return }
        log.error("\(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
        self.error = error.localizedDescription
    }
    private func endedSession(_ error: Error) -> Bool {
        guard (error as? AuthFailure)?.endsSession == true else { return false }
        log.notice("Google no longer accepts the session: signed out")
        connection = .signedOut
        return true
    }
    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    /// The conversation whose timeline is on screen: none while a shortcut is (Home keeps `selectedID` for its thread pane).
    private var openConversation: ConversationID? { shortcut == nil ? selectedID : nil }
    var unreadCount: Int { conversations.filter { !$0.muted }.reduce(0) { $0 + $1.unread } }
    /// The Dock menu's conversations: the unread ones the badge counts (not muted), most recent first, at most 10.
    var dockConversations: [Conversation] {
        Array(conversations.filter { $0.unread > 0 && !$0.muted }.sorted { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }.prefix(10))
    }
    /// The Dock menu's Mark All as Read: every unread conversation, muted ones included.
    func markAllRead() async {
        let unread = conversations.filter { $0.unread > 0 }.map(\.id)
        for i in conversations.indices where conversations[i].unread > 0 { conversations[i].unread = 0 }
        persist()
        for id in unread { await markRead(id) }
    }
    func key(_ conversation: String, _ thread: String?) -> String { "\(conversation)/\(thread ?? "timeline")" }
    func timeline(_ conversation: String, thread: String? = nil) -> [Message] {
        let all = messages   // read on every call, so a view showing it still updates when messages change
        let end = thread == nil ? windowEnds[conversation] : nil
        let scope = key(conversation, thread)
        if let cached = timelines[scope] { return cached }
        // A detached window ends at its newest loaded page: messages arriving live wait below it until paging down reaches them.
        let sorted = all.filter { $0.conversationID == conversation && $0.threadID == thread && (end == nil || $0.createdAt <= end!) }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        timelines[scope] = sorted
        return sorted
    }
    func start() async {
        if eventTask == nil {
            let events = backend.events
            eventTask = Task { [weak self] in
                for await event in events { guard !Task.isCancelled else { break }; self?.apply(event) }
            }
        }
        if sweepTask == nil {   // Google Chat sweeps typists every 3 s; presence goes stale after 60 s
            sweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    sweepTyping()
                    if isAppActive() { await refreshPresence(); await refreshInvitations() }
                }
            }
        }
        do {
            let known = cachedAccountID ?? (me.id.isEmpty ? nil : me.id)
            me = try await backend.connect()
            // A cache from a build that didn't record its account may be anyone's.
            if known.map({ $0 != me.id }) ?? !conversations.isEmpty { forgetAccount() }
            cachedAccountID = me.id
            try await refresh(reselect: true)
        } catch AuthFailure.signInRequired {
            connection = .signedOut
        } catch is CancellationError {   // superseded by a newer start, or its view went away: that one decides the state
        } catch { report(error); connection = .offline }
    }
    /// Replaces the conversation list (the server's, pin and mute included) and reloads the open conversation.
    /// A resync (`reselect: false`) keeps the open thread and edit and marks nothing read.
    func refresh(reselect: Bool = false) async throws {
        // Together, so Home never shows the new list with the old threads (a conversation flashing up as a plain row).
        let listed = try await backend.conversations()
        let threads = await backend.homeThreads()
        conversations = listed.filter { $0.hidden == nil }; hidden = listed.filter { $0.hidden != nil }; homeThreads = threads
        sections = await backend.sidebarSections()
        followed.formUnion(threads.map(\.id))   // Home's threads are the server's followed ones
        await refreshInvitations(force: true)
        await loadBlocked()
        let vanished = !conversations.contains(where: { $0.id == selectedID })
        if vanished { selectedID = conversations.first?.id }
        if let selectedID {
            if reselect || vanished {
                // A shortcut on screen (Home at launch) stays: the conversation opens, and is read, only when chosen.
                if shortcut == nil { await select(selectedID) }
            } else {
                loaded.remove(key(selectedID, nil))
                await load(selectedID)
                if let threadID {
                    loaded.remove(key(selectedID, threadID))
                    await load(selectedID, thread: threadID)
                }
            }
        }
        _ = await listDrafts()
        await listScheduled()
        persist()
        if !listedOnce {
            listedOnce = true
            let links = waitingLinks; waitingLinks = []
            for url in links { await open(url: url) }
        }
    }
    func select(_ id: String, recording: Bool = true) async {
        if recording { visit(.conversation(id)) }
        endMainWindowEdits()
        selectedID = id; threadID = nil; shortcut = nil
        heldUnread.removeAll()   // opening a conversation reads it, one marked unread from a message included
        loaded.remove(key(id, nil))   // no realtime yet: reselecting is how new messages arrive
        await load(id)
        await markRead(id)
        persist()
        await watchOpen()
        await refreshPresence()
    }
    /// A page already on its way is waited for, not skipped: a caller paging back (to reach an old message) must see it land.
    /// `quietly`: a background load (a Home preview) logs a failure instead of alerting.
    func load(_ id: String, thread: String? = nil, older: Bool = false, quietly: Bool = false) async {
        let scope = key(id, thread)
        if let running = pageLoads[scope] { await running.value; return }
        guard older || !loaded.contains(scope) else { return }
        // Cleared by the load itself, before anyone waiting on it resumes, so the next call starts a new page.
        let task = Task { await fetchPage(id, thread: thread, older: older, quietly: quietly); pageLoads[scope] = nil; loading.remove(scope) }
        pageLoads[scope] = task; loading.insert(scope)
        await task.value
    }
    @ObservationIgnored private var pageLoads: [String: Task<Void, Never>] = [:]
    /// Conversations showing a window of their history away from the newest messages (`open(_:at:)`), until paging down meets them.
    private(set) var detached: Set<ConversationID> = []
    /// A detached window's newest message.
    private var windowEnds: [ConversationID: Date] = [:] { didSet { timelines = [:] } }
    @ObservationIgnored private var newerLoads: Set<ConversationID> = []
    /// Opens a conversation at an old message, as web Chat opens a search result: the page around it instead of the newest.
    func open(_ id: ConversationID, at message: MessageID) async {
        visit(.conversation(id))
        endMainWindowEdits()
        selectedID = id; threadID = nil; shortcut = nil
        heldUnread.removeAll()
        await loadAround(message, in: id)
        await markRead(id)
        persist()
        await watchOpen()
        await refreshPresence()
    }
    /// The page around `message` replaces the conversation's timeline; a page already loading lands first.
    private func loadAround(_ message: MessageID, in id: ConversationID) async {
        let scope = key(id, nil)
        if let running = pageLoads[scope] { await running.value }
        loading.insert(scope); defer { loading.remove(scope) }
        do {
            let page = try await backend.messages(around: message, in: id)
            messages.removeAll { $0.conversationID == id && $0.threadID == nil && $0.delivery == .sent }
            page.messages.forEach(upsert)
            loaded.insert(scope)
            if page.hasMore { hasMore.insert(scope) } else { hasMore.remove(scope) }
            extendWindow(id, page)
        } catch { report(error) }
    }
    /// The timeline neared the bottom of a detached window: the next newer page, until the window meets the newest messages.
    func loadNewerIfNeeded(_ id: ConversationID) async {
        guard detached.contains(id), !newerLoads.contains(id) else { return }
        newerLoads.insert(id); defer { newerLoads.remove(id) }
        do {
            let page = try await backend.newerMessages(in: id)
            page.messages.forEach(upsert)
            extendWindow(id, page)
        } catch { report(error) }
    }
    private func extendWindow(_ id: ConversationID, _ page: MessagePage) {
        if page.hasNewer {
            detached.insert(id)
            if let newest = page.messages.map(\.createdAt).max() { windowEnds[id] = max(windowEnds[id] ?? newest, newest) }
        } else {
            detached.remove(id); windowEnds[id] = nil
        }
    }
    /// The scroll-down button, or a send, from a detached window: the newest messages again.
    func returnToNewest(_ id: ConversationID) async {
        detached.remove(id); windowEnds[id] = nil
        loaded.remove(key(id, nil))
        await load(id)
    }
    private func fetchPage(_ id: String, thread: String?, older: Bool, quietly: Bool = false) async {
        let scope = key(id, thread)
        do {
            let page = try await backend.messages(in: id, thread: thread, before: older ? timeline(id, thread: thread).first?.createdAt : nil)
            if !older {
                messages.removeAll { $0.conversationID == id && $0.threadID == thread && $0.delivery == .sent }
                if thread == nil { detached.remove(id); windowEnds[id] = nil }
            }
            page.messages.forEach(upsert)
            loaded.insert(scope)
            if page.hasMore { hasMore.insert(scope) } else { hasMore.remove(scope) }
            persist()
        } catch where quietly {
            log.error("Background load failed: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
        } catch { report(error) }
    }
    /// The timeline neared its top: load one older page, one request at a time per timeline. A page already on its
    /// way is waited for first, not a reason to drop the request: a reload of the newest page (reopening the
    /// conversation) lands the same rows, so the timeline would never ask again.
    func loadOlderIfNeeded(_ id: String, thread: String? = nil) async {
        let scope = key(id, thread)
        if let running = pageLoads[scope] { await running.value }
        guard hasMore.contains(scope), !loading.contains(scope) else { return }
        await load(id, thread: thread, older: true)
    }
    /// A click on a quote: highlights the quoted message. One not loaded brings the page around it, as web Chat does.
    func showQuoted(_ id: MessageID, in conversation: ConversationID) async {
        if !messages.contains(where: { $0.id == id }) { await loadAround(id, in: conversation) }
        guard let quoted = messages.first(where: { $0.id == id }) else { return }
        if let thread = quoted.threadID, thread != threadID { await openThread(quoted) }
        highlightedID = id
    }
    /// "Show in Chat" on a shared item: its message highlighted, in its thread when it is a reply.
    func showShared(_ item: SharedContent.Item, in conversation: ConversationID) async {
        guard let id = item.messageID else { return }
        await show(id, in: conversation)
    }
    /// A Google Chat link in a message: opens its conversation, and its message when it names one.
    /// Returns false when Parley doesn't know the conversation, for the caller to open the link elsewhere.
    @ObservationIgnored private var waitingLinks: [URL] = []
    @ObservationIgnored private var listedOnce = false
    /// A link sent to Parley (`open -a Parley <url>`, a link router): its conversation opens once the first conversation
    /// list is in. One this account can't open says so rather than going back to the browser, which could send it straight back.
    func open(url: URL) async {
        guard listedOnce else { waitingLinks.append(url); return }
        guard let link = ChatLink(url) else { log.notice("not a Google Chat link: ignored"); return }
        if !(await open(link)) { error = "This account isn't in the conversation that link goes to." }
    }
    func open(_ link: ChatLink) async -> Bool {
        guard let conversation = link.conversations.first(where: { id in conversations.contains { $0.id == id } }) else { return false }
        guard let topic = link.topic else { await select(conversation); return true }
        let id = "\(conversation)/\(topic)/\(link.message ?? topic)"
        // Straight to the page around it, as web Chat opens a message link, instead of the newest page first.
        if selectedID != conversation || shortcut != nil || !messages.contains(where: { $0.id == id || $0.id == "\(conversation)/\(topic)/\(topic)" }) {
            await open(conversation, at: id)
        }
        await show(id, in: conversation)
        return true
    }
    /// A message highlighted where it is: in its thread when it is a reply, else in the timeline, paging back to it.
    // ponytail: pages back through at most 50 pages of history; older messages stay unreachable until there is a jump-to-date.
    private func show(_ id: MessageID, in conversation: ConversationID) async {
        let parts = id.split(separator: "/")   // <conversation>/<topic>/<message>: a reply's message differs from its topic
        if parts.count >= 2, parts[parts.count - 1] != parts[parts.count - 2] {
            await openThread(parts.dropLast().joined(separator: "/") + "/" + parts[parts.count - 2], in: conversation)
            highlightedID = id
            return
        }
        await showQuoted(id, in: conversation)
        // A thread's first message with replies opens the thread, as web Chat opens a link to one.
        if let head = messages.first(where: { $0.id == id }), head.threadID == nil, head.replyCount > 0 { await openThread(head) }
    }
    /// The Threads button: shows the list when it isn't on screen (hidden, under an open thread, or replaced by the info
    /// panel), and closes it when it is.
    func toggleThreads() async {
        let onScreen = threadsShown && threadID == nil && !info
        await showThreads(!onScreen)
    }
    func showThreads(_ shown: Bool) async {
        threadsShown = shown
        guard shown, let id = selectedID else { return }
        info = false; threadID = nil
        await loadThreads(id)
    }
    func loadThreads(_ id: ConversationID) async {
        do { threadSummaries[id] = try await backend.threads(in: id) } catch { report(error) }
    }
    func openThread(_ message: Message) async {
        await openThread(message.threadID ?? message.id, in: message.conversationID)
    }
    private func openThread(_ thread: ThreadID, in conversation: ConversationID, recording: Bool = true) async {
        if recording, conversations.first(where: { $0.id == conversation })?.app == .gemini { visit(.session(conversation, thread)) }
        threadID = thread; info = false
        loaded.remove(key(conversation, thread))
        await load(conversation, thread: thread)
        await readThread(thread)
    }
    /// An open thread is read up to its newest reply, on the server too, so it reads as read on the web and phone.
    private func readThread(_ thread: ThreadID) async {
        guard let newest = messages.filter({ $0.threadID == thread || $0.id == thread }).map(\.createdAt).max() else { return }
        if let i = homeThreads.firstIndex(where: { $0.id == thread }) { homeThreads[i].unread = false }
        do { try await backend.markThreadRead(thread, upTo: newest) }
        catch { log.error("mark thread read failed: \(String(describing: error), privacy: .public)") }
    }
    func isFollowing(_ thread: ThreadID) -> Bool { followed.contains(thread) }
    /// Shown at once; Google's label event confirms it, and a refusal puts it back and says why.
    func setFollowing(_ following: Bool, thread: ThreadID) async {
        let was = followed.contains(thread)
        if following { followed.insert(thread) } else { followed.remove(thread) }
        do {
            try await backend.setFollowing(following, thread: thread)
            if !following { homeThreads.removeAll { $0.id == thread } }   // Home lists followed threads only
        } catch {
            if was { followed.insert(thread) } else { followed.remove(thread) }
            report(error)
        }
    }
    /// Posts a new Google Meet meeting in the conversation; its link, to open, or nil when refused (the error shows).
    func sendMeetLink(in id: ConversationID) async -> URL? {
        do {
            let message = try await backend.sendMeetLink(in: id)
            upsert(message)
            return message.attachments.first { $0.kind == .call }?.url
        } catch { report(error); return nil }
    }
    /// A picked "/" entry that runs at once: Google Chat's "Send a Meet link" (sent, then opened), or an app's quick
    /// command (its dialog, for the conversation).
    func run(_ command: SlashCommand, in conversation: ConversationID) async {
        switch command.action {
        case .meetLink: if let url = await sendMeetLink(in: conversation) { openURL(url) }
        case .quick:
            await openDialog(DialogContext(message: conversation, app: command.appID, command: command.id), app: command.appName,
                             in: conversation, action: nil, inputs: [])
        case nil: break
        }
    }
    /// Whether a restored window's conversation is this account's; nil until the list has come.
    func hasConversation(_ id: ConversationID) -> Bool? {
        conversations.isEmpty ? nil : conversations.contains { $0.id == id }
    }
    /// The open thread, closed in the pane so it can go to its own window.
    func detachThread(in conversation: ConversationID) -> ThreadRef? {
        guard let thread = threadID else { return nil }
        threadID = nil
        return ThreadRef(conversation: conversation, thread: thread)
    }
    // MARK: Back and forward, through the conversations and shortcuts opened (⌘[ and ⌘])

    /// An Ask Gemini session fills the page, so it is a place of its own; another conversation's thread is a side pane.
    enum Place: Hashable { case conversation(ConversationID), shortcut(Shortcut), session(ConversationID, ThreadID) }
    private(set) var backPlaces: [Place] = []
    private(set) var forwardPlaces: [Place] = []
    var canGoBack: Bool { !backPlaces.isEmpty || inGeminiSession }
    private var inGeminiSession: Bool { threadID != nil && selected?.app == .gemini }
    var canGoForward: Bool { !forwardPlaces.isEmpty }
    private var place: Place? {
        if inGeminiSession, let id = selectedID, let thread = threadID { return .session(id, thread) }
        return shortcut.map(Place.shortcut) ?? selectedID.map(Place.conversation)
    }
    /// Opening a new place: the current one goes on the back list and the forward list ends, as in a browser.
    private func visit(_ next: Place) {
        guard let place, place != next else { return }
        backPlaces.append(place); forwardPlaces = []
        if backPlaces.count > 100 { backPlaces.removeFirst() }
    }
    func goBack() async {
        guard let to = backPlaces.popLast() else {
            // A session opened with nothing before it (a notification at launch): Back still closes it to the home.
            if inGeminiSession, let place { forwardPlaces.append(place); threadID = nil }
            return
        }
        if let place { forwardPlaces.append(place) }
        await open(to)
    }
    func goForward() async {
        guard let to = forwardPlaces.popLast() else { return }
        if let place { backPlaces.append(place) }
        await open(to)
    }
    private func open(_ place: Place) async {
        switch place {
        case .conversation(let id): await select(id, recording: false)
        case .shortcut(let shortcut): await openShortcut(shortcut, recording: false)
        case .session(let id, let thread):
            await select(id, recording: false)
            await openThread(thread, in: id, recording: false)
        }
    }

    /// A clicked notification: its conversation, and its thread for a reply.
    func open(conversation: ConversationID, thread: ThreadID?) async {
        await select(conversation)
        if let thread { await openThread(thread, in: conversation) }
    }
    func apply(_ event: ChatEvent) {
        if case .connectionChanged(let state) = event {
            if state != .connected { connectedSince = nil } else if connection != .connected { connectedSince = now() }
            if state == .reconnecting, connection != .reconnecting { reconnects += 1 }
        } else { lastEventAt = now() }
        switch event {
        case .messageUpserted(let message):
            let isNew = !messages.contains { $0.id == message.id }
            upsert(message)
            // A pin posts a service line: the board on screen reads again.
            if isNew, message.isSystem, pinned[message.conversationID] != nil { Task { await loadPinned(message.conversationID) } }
            // A new message changes the threads listed on screen (Ask Gemini's home, the Threads pane): they read again.
            // ponytail: one read per new message; debounce if a busy room with its Threads pane open makes this chatty.
            if isNew, message.conversationID == selectedID, threadSummaries[message.conversationID] != nil, threadsShown || selected?.app == .gemini {
                Task { await loadThreads(message.conversationID) }
            }
            // A newer reply in a thread Home lists moves its row up.
            // Threads already listed; a reply in another one re-reads Home's threads (checkFollowed, below).
            if let thread = message.threadID, let i = homeThreads.firstIndex(where: { $0.id == thread }), message.createdAt > homeThreads[i].latest.createdAt {
                homeThreads[i].latest = message
                homeThreads[i].time = max(homeThreads[i].time, message.createdAt)
                if message.sender.id != me.id, !(shortcut == .home && threadID == thread) { homeThreads[i].unread = true }
            }
            // A new reply in the thread open on screen is read as it arrives.
            if isNew, let thread = message.threadID, thread == threadID, message.conversationID == selectedID, isAppActive() {
                Task { await readThread(thread) }
            }
            if isNew, message.sender.id != me.id {   // a message ends its sender's typing, and they're evidently here
                for scope in typing.keys where scope.hasPrefix(message.conversationID + "/") { typing[scope]?[message.sender.id] = nil }
                if now().timeIntervalSince(message.createdAt) < Self.presenceTTL { markActive(message.sender.id) }
            }
            if isNew, message.sender.id != me.id, !announce(message), let thread = message.threadID, !followed.contains(thread),
               let level = conversations.first(where: { $0.id == message.conversationID })?.notificationLevel,
               level.notifies(head: false, followed: true, mentioned: false), !level.notifies(head: false, followed: false, mentioned: false) {
                checkFollowed(message)
            } else if isNew, message.sender.id != me.id, let thread = message.threadID, !homeThreads.contains(where: { $0.id == thread }) {
                checkFollowed(nil)   // Home may list it now
            }
            // Only a fresh message is unread: a reaction or edit pushes an old message the user has long since read.
            if isNew, !message.isSystem, message.threadID == nil, message.sender.id != me.id, message.conversationID != openConversation,
               now().timeIntervalSince(message.createdAt) < Self.unreadWindow,
               let i = conversations.firstIndex(where: { $0.id == message.conversationID }) {
                conversations[i].unread += 1
            }
            // ponytail: one read receipt per pushed message; debounce if busy rooms make this chatty.
            if isNew, message.sender.id != me.id, message.conversationID == openConversation, isAppActive(), !heldUnread.contains(message.conversationID) {
                Task { await markRead(message.conversationID) }
            }
        case .messageDeleted(let id):
            // A thread's first message takes the thread with it, as Google Chat deletes it; Google sends only this one.
            messages.removeAll { $0.id == id || $0.threadID == id }
            homeThreads.removeAll { $0.id == id }
            if threadID == id { threadID = nil }
        case .conversationUpserted(let room) where room.hidden != nil:   // hidden here or elsewhere: off the sidebar, into Settings' list
            apply(.conversationRemoved(room.id))
            hidden.insert(room, at: 0)
        case .conversationUpserted(var room):   // changed elsewhere; a new one is the most recent
            hidden.removeAll { $0.id == room.id }
            // The open conversation stays read: its server read state can trail what is on screen (my own send, a membership change).
            if room.id == openConversation, room.unread > 0, isAppActive(), !heldUnread.contains(room.id) {
                room.unread = 0
                Task { await markRead(room.id) }
            }
            if let i = conversations.firstIndex(where: { $0.id == room.id }) { conversations[i] = room } else { conversations.insert(room, at: 0) }
            // Members or roles may have changed: what is on screen is read again.
            if members[room.id] != nil { Task { await reloadMembers(room.id) } }
            if permissions[room.id] != nil { Task { await loadPermissions(room.id) } }
        case .conversationRemoved(let id):
            conversations.removeAll { $0.id == id }
            hidden.removeAll { $0.id == id }
            messages.removeAll { $0.conversationID == id }
            notifier?.clear(conversation: id)
            if selectedID == id {
                editing = editing.filter { !$0.key.hasPrefix(id + "/") }; heldDrafts = heldDrafts.filter { !$0.key.hasPrefix(id + "/") }
                selectedID = conversations.first?.id; threadID = nil
                if let next = selectedID { Task { await select(next) } }
            }
        case .threadFollowChanged(let thread, let following):
            if following { followed.insert(thread) } else { followed.remove(thread) }
        case .reacted(let id, let emoji, let person, let added):
            // ponytail: only reactions to my messages loaded here notify; fetch the message if older ones go unannounced.
            let target = messages.first { $0.id == id }
            log.notice("reaction pushed: \(added ? "added" : "removed", privacy: .public), message \(target == nil ? "not loaded" : target?.sender.id == self.me.id ? "mine" : "someone else's", privacy: .public)")
            guard added, let message = target,
                  let notification = NotificationPolicy.reaction(
                    emoji, by: self.person(person, in: message.conversationID) ?? Person(id: person, name: name(of: person, in: message.conversationID)),
                    to: message, in: conversations.first { $0.id == message.conversationID }, me: me.id, openConversation: selectedID,
                    openThread: threadID, timelineShown: shortcut == nil, appActive: isAppActive(), settings: notificationSettings()),
                  notifiedReactions.insert(notification.id).inserted else { return }
            notifier?.post(notification)
            return
        case .readStateChanged(let id, let count):
            if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].unread = count }
            if count == 0 { notifier?.clear(conversation: id) }   // read here or on another device
        case .connectionChanged(let state):
            connection = state
            if state != .connected { typing = [:] }   // nobody's typing reaches us now
        case .activityChanged(let id, let thread, let person, let label):
            for scope in Set([key(id, nil), key(id, thread)]) {
                activities[scope] = label.map { Activity(person: person, label: $0, at: now()) }
            }
            return
        case .typingChanged(let id, let thread, let person, let isTyping):
            if isTyping { typing[key(id, thread), default: [:]][person] = now(); markActive(person) }
            else { typing[key(id, thread)]?[person] = nil }
            return
        case .readReceiptsChanged(let id, let reads, let enabled):
            if enabled == false { receiptsOff.insert(id); readReceipts[id] = nil; return }
            if enabled == true { receiptsOff.remove(id) }
            if !receiptsOff.contains(id) { readReceipts[id, default: [:]].merge(reads, uniquingKeysWith: max) }
            return
        case .presenceChanged(let person, let state, let status):
            statuses[person] = status
            if let state { presence[person] = state; presenceFetched[person] = now() }
            else if presence[person] == .doNotDisturb { presence[person] = nil; presenceFetched[person] = nil }   // DND over: ask again
            return
        case .ownStatusChanged(let status):
            ownStatus = status
            return
        case .resync:
            resync()
        case .draftChanged(let draft):
            let scope = key(draft.conversationID, draft.threadID)
            if spentDrafts.contains(draft.id) { break }   // sent: an echo of an earlier save, not a draft
            if draft.schedule != nil { keepScheduled(draft); break }
            // Our own save comes back too, possibly after a newer one: only a newer copy counts.
            if let held = serverDrafts[scope], held.id == draft.id, held.updatedAt >= draft.updatedAt { break }
            serverDrafts[scope] = draft
            // The user typing here wins: their text replaces this at the next save.
            if draftEdits[scope] == nil, draftWrites[scope] == nil, !isEditing(scope) { fill(scope, with: draft) }
        case .draftDeleted(let id):
            scheduled.removeAll { $0.id == id }   // sent at its time, or cancelled elsewhere
            guard let (scope, held) = serverDrafts.first(where: { $0.value.id == id }) else { break }   // ours, or a send's
            serverDrafts[scope] = nil
            // Sent or deleted elsewhere: the composer empties, unless it holds text not yet saved.
            if draftEdits[scope] == nil, drafts[scope] == held.text, !isEditing(scope) { drafts[scope] = nil; draftFormatting[scope] = nil }
        }
        persist()
    }
    private func markActive(_ person: String) {
        guard person != me.id else { return }
        if presence[person] != .doNotDisturb { presence[person] = .available }
        presenceFetched[person] = now()
    }
    /// Typists whose last "typing" arrived more than 8 s ago are gone. Google Chat times from the server's
    /// start time, which a fast Mac clock would expire on arrival, so this uses the local arrival time.
    func sweepTyping() {
        let cutoff = now().addingTimeInterval(-Self.typingTimeout)
        activities = activities.filter { $0.value.at > now().addingTimeInterval(-15) }   // an agent repeats its status every few seconds
        for (scope, people) in typing where people.values.contains(where: { $0 <= cutoff }) {
            let kept = people.filter { $0.value > cutoff }
            typing[scope] = kept.isEmpty ? nil : kept
        }
    }
    /// "Ask Gemini · Collecting info…" while an agent works where this composer is; `name` for the agent's, else looked up.
    func activityLine(_ conversation: ConversationID, thread: ThreadID?, name: String? = nil) -> String? {
        guard let activity = activities[key(conversation, thread)] else { return nil }
        return "\(name ?? self.name(of: activity.person, in: conversation)) · \(activity.label)…"
    }
    func typists(_ conversation: ConversationID, thread: ThreadID? = nil) -> [String] {
        (typing[key(conversation, thread)] ?? [:]).keys.sorted()
    }
    static func typingLine(_ names: [String]) -> String? {
        let first = names.map { String($0.split(separator: " ").first ?? Substring($0)) }
        switch first.count {
        case 0: return nil
        case 1: return "\(first[0]) is typing…"
        case 2, 3: return "\(ListFormatter.localizedString(byJoining: first)) are typing…"
        default: return "Several people are typing…"
        }
    }
    /// Posts a pushed message's banner when the notification policy allows it; false when it doesn't.
    @discardableResult
    private func announce(_ message: Message) -> Bool {
        let room = conversations.first { $0.id == message.conversationID }
        // A call notifies even with its DM on screen, as a phone call would.
        let call = NotificationPolicy.isIncomingCall(message, in: room, me: me.id, now: now())
        let notification = NotificationPolicy.notification(
            for: message, in: room, me: me.id, openConversation: selectedID,
            openThread: threadID, timelineShown: shortcut == nil, appActive: !call && isAppActive(), settings: notificationSettings(),
            threadFollowed: message.threadID.map(followed.contains) ?? false)
            .map { call ? $0.incomingCall(join: message.attachments.first { $0.kind == .call }?.url) : $0 }
        if notification == nil {
            // Why not, for "notifications don't show" reports: nothing here names the conversation or the sender.
            let level = room?.notificationLevel.map { "\($0)" } ?? "unknown", followed = message.threadID.map(followed.contains)
            log.notice("message pushed: no banner (level \(level, privacy: .public), \(message.threadID == nil ? "new thread" : followed == true ? "followed reply" : "unfollowed reply", privacy: .public), muted \(room?.muted ?? false, privacy: .public), app active \(self.isAppActive(), privacy: .public), open here \(message.conversationID == self.selectedID, privacy: .public))")
        } else {
            log.notice("message pushed: \(self.notifier == nil ? "no notifier" : "banner", privacy: .public)")
        }
        if let notification { notifier?.post(notification) }
        return notification != nil
    }
    @ObservationIgnored private var followCheck: Task<Void, Never>?
    @ObservationIgnored private var awaitingFollow: [Message] = []
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var resyncAgain = false
    /// The server says Parley missed events: refresh. A resync during one runs once more after it, so a burst (a flapping
    /// connection) is two refreshes, never several at once finishing out of order.
    private func resync() {
        guard resyncTask == nil else { resyncAgain = true; return }
        resyncTask = Task {
            repeat {
                resyncAgain = false
                do { try await refresh() } catch { report(error) }
            } while resyncAgain
            resyncTask = nil
        }
    }
    @ObservationIgnored private var followAsked = ContinuousClock.now
    /// Google lists a reply's thread a moment after pushing the reply, so the read right after a push can miss it.
    // ponytail: in a busy space with replies in threads Home doesn't list, this reads the world every 5 s; listen for the
    // topic's own update if that load shows.
    @ObservationIgnored var followRecheck: Duration = .seconds(5)
    /// A reply in a thread Home doesn't list: re-read the server's followed threads (Home's) so Home shows it, and post the
    /// banner of a `message` whose notification depends on following. One read right away and one `followRecheck` after
    /// the last such reply; a burst between them waits for that one.
    private func checkFollowed(_ message: Message?) {
        if let message { awaitingFollow.append(message) }
        followAsked = .now
        guard followCheck == nil else { return }
        followCheck = Task {
            defer { followCheck = nil }
            var read: ContinuousClock.Instant?
            while read.map({ $0 < followAsked + followRecheck }) ?? true {
                if read != nil { try? await Task.sleep(until: max(.now, followAsked + followRecheck)) }
                read = .now
                // Google sends Home's threads with the conversation list; only the threads are taken. The list itself stays
                // as Parley has it: a read that started before a hide, mute, pin or pushed message would undo it.
                guard (try? await backend.conversations()) != nil else { continue }
                let threads = await backend.homeThreads()
                homeThreads = threads
                followed.formUnion(threads.map(\.id))
                let found = awaitingFollow.filter { $0.threadID.map(followed.contains) == true }
                awaitingFollow.removeAll { message in found.contains { $0.id == message.id } }
                found.forEach { announce($0) }
            }
            awaitingFollow = []
        }
    }
    /// The composer's text changed: tell the others at most every 5 s per composer, never for blank text or while
    /// editing a sent message. There is no "stopped"; receivers time it out.
    func typed(_ text: String, conversation: ConversationID, thread: ThreadID?) async {
        let scope = key(conversation, thread)
        guard editing[scope] == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !typingRefused.contains(scope) else { return }
        if let last = typingSent[scope], now().timeIntervalSince(last) < Self.typingInterval { return }
        typingSent[scope] = now()   // before any wait, so keystrokes meanwhile don't ask again
        // Whether Google lets me send typing here (a space's capability); asked once per space.
        if permissions[conversation] == nil { await loadPermissions(conversation) }
        guard permissions[conversation]?.typing != false else { log.notice("typing not sent: not allowed in this space"); return }
        do { try await backend.sendTyping(conversation: conversation, thread: thread) }
        catch AuthFailure.http(403) { typingRefused.insert(scope) }
        catch {}
    }
    // ponytail: only the main window's conversation is watched; add the extra windows' ones if typing is wanted there too.
    private func watchOpen() async {
        let open: Set<ConversationID> = selectedID.map { [$0] } ?? []
        guard open != watching else { return }
        watching = open
        await backend.watch(open)
    }
    func setDoNotDisturb(for duration: TimeInterval) async { await setOwnStatus { try await $0.setDoNotDisturb(for: duration) } }
    func setAway(_ away: Bool) async { await setOwnStatus { try await $0.setAway(away) } }
    func setCustomStatus(_ status: CustomStatus?) async { await setOwnStatus { try await $0.setCustomStatus(status) } }
    private func setOwnStatus(_ change: (any ChatBackend) async throws -> OwnStatus) async {
        do { ownStatus = try await change(backend) } catch { report(error) }
    }
    /// Asks, in one batch, for everyone whose presence is over 60 s old among 1:1 partners and the open conversation's members.
    // ponytail: the 50 most recent 1:1 DMs; page through the rest if the sidebar shows more dots than that.
    func refreshPresence() async {
        let partners = conversations.compactMap(partner).prefix(50)
        let open = selectedID.map(mentionCandidates)?.map(\.id) ?? []
        let stale = Set(partners + open).subtracting([me.id, ""]).filter { id in
            presenceFetched[id].map { now().timeIntervalSince($0) >= Self.presenceTTL } ?? true
        }
        guard !stale.isEmpty else { return }
        for id in stale { presenceFetched[id] = now() }   // also spaces out retries after a failure
        try? await backend.fetchPresence(stale.sorted())
    }
    /// Each reader under my newest message their read time covers: DMs and group DMs only.
    func seen(in conversation: Conversation) -> [MessageID: [String]] {
        guard conversation.kind != .space, let reads = readReceipts[conversation.id] else { return [:] }
        let mine = timeline(conversation.id).filter { $0.sender.id == me.id && $0.delivery == .sent }
        var marks: [MessageID: [String]] = [:]
        for (reader, time) in reads.sorted(by: { $0.key < $1.key }) {
            if let newest = mine.last(where: { $0.createdAt <= time }) { marks[newest.id, default: []].append(reader) }
        }
        return marks
    }
    /// Everyone whose receipt covers `message`, for "Seen by …".
    func readers(of message: Message) -> [String] {
        (readReceipts[message.conversationID] ?? [:]).filter { $0.value >= message.createdAt }.keys.sorted()
    }
    /// "Alice, Bob, and You" for a reaction pill's hover card, fetched once per reaction state; nil when the lookup failed.
    /// Keyed by the `Reaction` value, so a reaction that changes (people or count) is looked up again.
    func reactorsLine(_ reaction: Reaction, on message: MessageID) async -> String? {
        if reactors[message]?[reaction] == nil {
            guard let people = try? await backend.reactors(of: message, emoji: reaction.emoji, custom: reaction.custom) else { return nil }
            reactors[message, default: [:]][reaction] = people
        }
        let people = reactors[message]?[reaction] ?? []
        return Self.reactorsLine(names: people.map { $0.id == me.id ? "You" : $0.name }, count: reaction.people.count)
    }
    /// Others first, then "You", as Google Chat lists them; people the server left out are counted. No names yet: the count.
    static func reactorsLine(names: [String], count: Int) -> String {
        guard !names.isEmpty else { return count == 1 ? "1 person" : "\(count) people" }
        var list = names.filter { $0 != "You" } + names.filter { $0 == "You" }
        if count > names.count { list.append(count - names.count == 1 ? "1 other" : "\(count - names.count) others") }
        return ListFormatter.localizedString(byJoining: list)
    }
    /// The other person in a 1:1 DM, whose presence the sidebar and header show.
    func partner(in conversation: Conversation) -> String? {
        conversation.kind == .direct ? conversation.members.first { $0.id != me.id }?.id : nil
    }
    func name(of person: String, in conversation: ConversationID) -> String {
        let known = (members[conversation] ?? []) + (conversations.first { $0.id == conversation }?.members ?? [])
        return (known.first { $0.id == person } ?? messages.first { $0.sender.id == person }?.sender)
            .map(\.name).flatMap { $0 == "Unknown" ? nil : $0 } ?? "Someone"
    }
    /// Who `id` is, as far as the conversation knows: its members, then the senders of loaded messages.
    func person(_ id: PersonID, in conversation: ConversationID) -> Person? {
        let known = (members[conversation] ?? []) + (conversations.first { $0.id == conversation }?.members ?? [])
        return known.first { $0.id == id && $0.name != "Unknown" } ?? messages.first { $0.sender.id == id }?.sender
    }
    /// A card button's action (a Drive comment's Reply, Resolve, a poll's Vote): sent with the card's id and inputs; the
    /// app's answer replaces the message. A refusal says why, naming the app as Google Chat does. A button that opens the
    /// app's dialog opens it (`openDialog`).
    func clickCard(_ message: Message, card: String?, action: Data, inputs: [Card.Input]) async {
        let cards = message.attachments.compactMap(\.card)
        if let owner = cards.first(where: { $0.links.contains { $0.action == action && $0.dialog == true } }) {
            let app = owner.app ?? message.sender.id
            await openDialog(DialogContext(message: message.id, app: app), app: owner.by?.name ?? message.sender.name,
                             in: message.conversationID, action: action, inputs: inputs)
            return
        }
        do { if let updated = try await backend.clickCard(message.id, card: card, action: action, inputs: inputs) { upsert(updated); persist() } }
        catch DynamiteError.appRefused(let why) { self.error = "\(message.sender.name) is unable to process your request." + (why.isEmpty ? "" : " " + why) }
        catch { report(error) }
    }
    /// An app's dialog showing over its conversation, with what the app last said was wrong.
    struct OpenDialog: Hashable {
        var context: DialogContext
        var conversation: ConversationID
        var app: String          // its name, for the sheet's title when the card has none and for errors
        var dialog: AppDialog
        var problem: String? = nil
    }
    var dialog: OpenDialog?
    /// A short note shown for a moment over the conversation (an app's "Poll started."); it fades after `toastDuration`.
    var toast: String? {
        didSet {
            toastFade?.cancel()
            guard toast != nil else { return }
            toastFade = Task { [weak self, toastDuration] in
                try? await Task.sleep(for: toastDuration)
                guard !Task.isCancelled else { return }
                self?.toast = nil
            }
        }
    }
    @ObservationIgnored var toastDuration: Duration = .seconds(3)
    @ObservationIgnored private var toastFade: Task<Void, Never>?
    /// Opens links an app's answer asks for (its setup page); tests record them.
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Opens an app's dialog: from a card's button (its action and the card's inputs), or with no action for a slash
    /// command's message. A refusal shows as an error; the dialog shows in a sheet over `conversation`.
    func openDialog(_ context: DialogContext, app: String, in conversation: ConversationID, action: Data?, inputs: [Card.Input]) async {
        do {
            let answer = try await backend.dialog(.open, context, action: action, inputs: inputs)
            if case .show(let shown) = answer { dialog = OpenDialog(context: context, conversation: conversation, app: app, dialog: shown) }
            else { apply(answer, app: app) }
        } catch { report(error) }
    }
    /// One of the open dialog's buttons: its action with every input. The app answers with the next step (same sheet),
    /// what's wrong (kept open, said in the sheet), or done (closed, with its note as a toast).
    func submitDialog(action: Data, inputs: [Card.Input]) async {
        guard let open = dialog else { return }
        do {
            let answer = try await backend.dialog(.submit, open.context, action: action, inputs: inputs)
            guard dialog?.context == open.context else { return }   // closed meanwhile
            apply(answer, app: open.app)
        } catch {
            guard dialog?.context == open.context else { return }
            dialog?.problem = error.localizedDescription
        }
    }
    /// Closes the dialog (✕, Escape) and tells the app, as Google Chat does, without waiting for its answer.
    func cancelDialog() async {
        guard let open = dialog else { return }
        dialog = nil
        _ = try? await backend.dialog(.cancel, open.context, action: nil, inputs: [])
    }
    private func apply(_ answer: DialogAnswer, app: String) {
        switch answer {
        case .show(let next): dialog?.dialog = next; dialog?.problem = nil
        case .close(let note): dialog = nil; if let note { toast = note }
        case .invalid(let why):
            let text = why.isEmpty ? "\(app) is unable to process your request." : why
            if dialog != nil { dialog?.problem = text } else { error = text }
        case .configure(let url): dialog = nil; openURL(url)
        }
    }
    /// Where dismissed cards are remembered; tests use their own.
    @ObservationIgnored var defaults = UserDefaults.standard
    private static let dismissedCardsKey = "dismissedCards"
    /// Hides a message's dismissible cards (an app suggestion's "Don't install"), in Parley only, for good.
    func dismissCard(of message: Message) {
        let dismissed = defaults.stringArray(forKey: Self.dismissedCardsKey) ?? []
        // ponytail: an ever-growing list of message ids; trim it if it ever gets long.
        if !dismissed.contains(message.id) { defaults.set(dismissed + [message.id], forKey: Self.dismissedCardsKey) }
        if let current = messages.first(where: { $0.id == message.id }) { upsert(current); persist() }   // the launch cache too
    }
    private func upsert(_ message: Message) {
        var message = message
        if message.attachments.contains(where: { $0.card?.dismiss != nil }),
           defaults.stringArray(forKey: Self.dismissedCardsKey)?.contains(message.id) == true {
            message.attachments.removeAll { $0.card?.dismiss != nil }
        }
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message } else { messages.append(message) }
        // Following, as the server does it: a thread loaded as followed, or one I start, reply in or am @mentioned in.
        if message.following || message.sender.id == me.id || NotificationPolicy.mentions(message, me: me.id) {
            followed.insert(message.threadID ?? message.id)
        }
    }
    func setDraft(_ text: String, formatting: [TextStyleRange] = [], conversation: String, thread: String?) {
        let scope = key(conversation, thread)
        let changed = drafts[scope, default: ""] != text || draftFormatting[scope, default: []] != formatting
        drafts[scope] = text; draftFormatting[scope] = formatting.isEmpty ? nil : formatting
        if changed, !isEditing(scope) { draftEdits[scope] = now(); scheduleDraftSave(scope) }   // an edit's text is no draft
        persist()
    }
    // MARK: Server drafts
    /// Whether `scope` holds a sent message being edited, whose text is no draft.
    private func isEditing(_ scope: String) -> Bool {
        editing[scope] != nil
    }
    /// A draft key's conversation and thread, for a conversation the sidebar knows; nil for any other.
    private func place(_ scope: String) -> (ConversationID, ThreadID?)? {
        guard let room = conversations.first(where: { scope.hasPrefix($0.id + "/") }) else { return nil }
        let rest = String(scope.dropFirst(room.id.count + 1))
        return (room.id, rest == "timeline" ? nil : rest)
    }
    private func fill(_ scope: String, with draft: ServerDraft) {
        drafts[scope] = draft.text; draftFormatting[scope] = draft.formatting.isEmpty ? nil : draft.formatting; draftEdits[scope] = nil
    }
    private static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// After a pause in typing, a draft Google doesn't have yet is created (or a cleared one deleted); after a longer
    /// idle, a changed one is updated too.
    private func scheduleDraftSave(_ scope: String) {
        draftTimers[scope]?.cancel()
        draftTimers[scope] = Task { [weak self, draftPause, draftIdle] in
            try? await Task.sleep(for: draftPause)
            guard !Task.isCancelled else { return }
            await self?.syncDraft(scope, updating: false)
            try? await Task.sleep(for: draftIdle - draftPause)
            guard !Task.isCancelled else { return }
            await self?.syncDraft(scope)
        }
    }
    /// Leaving composers (another conversation or thread, the window losing focus, quitting) saves every draft typed in
    /// since its last save. The task ends when they are saved, or failed.
    @discardableResult func saveDrafts() -> Task<Void, Never> {
        let scopes = draftsListed ? draftEdits.keys.sorted() : []   // before the first list the merge pushes them
        return Task { for scope in scopes { await syncDraft(scope) } }
    }
    /// Brings Google's copy of one composer's draft in line with the composer: created when it has text Google lacks, deleted
    /// when it is empty, updated (`updating`) when its text or formatting changed. One write at a time per composer; a
    /// failure keeps the text and the edit mark, so the next trigger tries again.
    func syncDraft(_ scope: String, updating: Bool = true) async {
        while let running = draftWrites[scope] { await running.value }
        if !draftsListed { guard await listDrafts() else { return } }
        guard !isEditing(scope), let (conversation, thread) = place(scope) else { return }
        let text = drafts[scope] ?? "", formatting = draftFormatting[scope] ?? []
        let held = serverDrafts[scope]
        if Self.blank(text) ? held == nil : held.map({ $0.text == text && $0.formatting == formatting }) ?? false {
            draftEdits[scope] = nil   // nothing to save
            return
        }
        if held != nil, !Self.blank(text), !updating { return }
        let sends = draftSends[scope, default: 0]
        let task = Task {
            do {
                if Self.blank(text), let held {
                    try await backend.deleteDraft(held)
                    if serverDrafts[scope]?.id == held.id { serverDrafts[scope] = nil }
                } else {
                    let saved = try await backend.saveDraft(ServerDraft(id: held?.id ?? "", conversationID: conversation, threadID: thread,
                                                                        text: text, formatting: formatting))
                    if draftSends[scope, default: 0] != sends {
                        // The message went while this was on its way: Google now holds its old text as a draft. Undone.
                        spentDrafts.insert(saved.id)
                        try await backend.deleteDraft(saved)
                        draftWrites[scope] = nil
                        return
                    }
                    serverDrafts[scope] = saved
                }
                if drafts[scope] ?? "" == text, draftFormatting[scope] ?? [] == formatting { draftEdits[scope] = nil }
            } catch {
                log.error("draft not saved: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
                _ = endedSession(error)
            }
            draftWrites[scope] = nil
            persist()
        }
        draftWrites[scope] = task
        await task.value
    }
    /// Google's drafts, merged with this Mac's: a draft only Google has fills its composer; one only this Mac has is pushed,
    /// unless it was saved before and Google no longer has it (sent or deleted elsewhere); when both have one, the newer
    /// wins, by Google's update time against the last local edit. False when the list failed; the next save asks again.
    @discardableResult func listDrafts() async -> Bool {
        if let draftListing { return await draftListing.value }
        let listing = Task { () -> Bool in
            defer { draftListing = nil }
            let list: [ServerDraft]
            do { list = try await backend.drafts() } catch {
                log.error("drafts not listed: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
                _ = endedSession(error)
                return false
            }
            let known = serverDrafts
            serverDrafts = Dictionary(list.filter { !spentDrafts.contains($0.id) }.map { (key($0.conversationID, $0.threadID), $0) },
                                      uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
            draftsListed = true
            var push: [String] = []
            for (scope, draft) in serverDrafts where !isEditing(scope) {
                if let edited = draftEdits[scope], edited > draft.updatedAt { push.append(scope) } else { fill(scope, with: draft) }
            }
            for (scope, text) in drafts where serverDrafts[scope] == nil && !Self.blank(text) && !isEditing(scope) {
                if draftEdits[scope] == nil, known[scope]?.text == text { drafts[scope] = nil; draftFormatting[scope] = nil }
                else { push.append(scope) }
            }
            for scope in push.sorted() { Task { await syncDraft(scope) } }
            persist()
            return true
        }
        draftListing = listing
        return await listing.value
    }
    /// The Drafts shortcut: every composer holding a draft, newest first. `updatedAt` is when it last changed, here or on
    /// Google (`.distantPast` when unknown).
    func draftList() -> [ServerDraft] {
        drafts.compactMap { scope, text -> ServerDraft? in
            guard !Self.blank(text), !isEditing(scope), let (conversation, thread) = place(scope) else { return nil }
            let edited = draftEdits[scope].flatMap { $0 == .distantPast ? nil : $0 }
            return ServerDraft(id: serverDrafts[scope]?.id ?? "", conversationID: conversation, threadID: thread, text: text,
                               formatting: draftFormatting[scope] ?? [], updatedAt: edited ?? serverDrafts[scope]?.updatedAt ?? .distantPast)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.conversationID < $1.conversationID : $0.updatedAt > $1.updatedAt }
    }
    // Scheduled send, as Google Chat's: the server keeps the message and sends it at its time.
    func listScheduled() async {
        do { scheduled = try await backend.scheduled().sorted(by: Self.soonest) } catch {
            log.error("scheduled messages not listed: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
            _ = endedSession(error)
        }
    }
    func scheduled(in conversation: ConversationID, thread: ThreadID?) -> [ServerDraft] {
        scheduled.filter { $0.conversationID == conversation && $0.threadID == thread }
    }
    /// Only text can wait, as on the web: no files, quote or forward, and not an edit.
    func canSchedule(conversation: String, thread: String?) -> Bool {
        let scope = key(conversation, thread)
        return !Self.blank(drafts[scope] ?? "") && editing[scope] == nil && (draftAttachments[scope] ?? []).isEmpty && quoting[scope] == nil
    }
    /// The composer's text goes to Google to send at `date`; the composer empties, which drops its own draft as a send does.
    func schedule(conversation: String, thread: String? = nil, at date: Date) async {
        guard canSchedule(conversation: conversation, thread: thread) else { return }
        let scope = key(conversation, thread)
        let (text, formatting) = Self.trimmed(drafts[scope, default: ""], draftFormatting[scope] ?? [])
        do {
            keepScheduled(try await backend.saveDraft(ServerDraft(conversationID: conversation, threadID: thread, text: text,
                                                                  formatting: formatting, schedule: .init(at: date))))
            setDraft("", conversation: conversation, thread: thread)
        } catch { report(error) }
    }
    /// Sends it now, naming it so Google drops it, as Google Chat's Send now does.
    func sendNow(_ message: ServerDraft) async {
        scheduled.removeAll { $0.id == message.id }
        spentDrafts.insert(message.id)
        await sendNew(message.text, formatting: message.formatting, serverDraft: message.id, conversation: message.conversationID, thread: message.threadID)
    }
    func reschedule(_ message: ServerDraft, to date: Date) async {
        do { keepScheduled(try await backend.reschedule(message, to: date)) } catch { report(error) }
    }
    func unschedule(_ message: ServerDraft) async {
        do { try await backend.deleteDraft(message); scheduled.removeAll { $0.id == message.id } } catch { report(error) }
    }
    private func keepScheduled(_ message: ServerDraft) {
        scheduled.removeAll { $0.id == message.id }
        scheduled.append(message)
        scheduled.sort(by: Self.soonest)
    }
    private static func soonest(_ a: ServerDraft, _ b: ServerDraft) -> Bool { (a.schedule?.at ?? .distantPast) < (b.schedule?.at ?? .distantPast) }
    /// The threads in `conversation` whose reply box holds a draft, for the "1 draft" under their first message.
    func threadsWithDrafts(in conversation: ConversationID) -> Set<ThreadID> {
        Set(draftedScopes.compactMap { scope -> ThreadID? in
            guard !isEditing(scope), let (room, thread) = place(scope), room == conversation else { return nil }
            return thread
        })
    }
    /// People who can be @-mentioned: the conversation's full member list once loaded, else the members it came with; never me.
    func mentionCandidates(_ conversation: ConversationID) -> [Person] {
        (members[conversation] ?? conversations.first { $0.id == conversation }?.members ?? []).filter { $0.id != me.id }
    }
    /// Fetches a conversation's members once per launch; a failure keeps the fallback and allows a later retry.
    func sharedKey(_ conversation: ConversationID, _ category: SharedCategory) -> String { "\(conversation)/\(category.rawValue)" }
    /// The first page of a tab when it first shows, or the next page. A failure keeps the panel on loaded messages.
    func loadShared(_ category: SharedCategory, in conversation: ConversationID, more: Bool = false) async {
        let key = sharedKey(conversation, category)
        guard more ? sharedMore.contains(key) : shared[key] == nil else { return }
        sharedMore.remove(key)   // one request at a time
        do {
            let page = try await backend.shared(category, in: conversation, after: more ? shared[key]?.last : nil)
            var items = shared[key] ?? []
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            shared[key] = items
            if page.hasMore { sharedMore.insert(key) }
        } catch is CancellationError {
            if more { sharedMore.insert(key) }
        } catch {
            if (error as? AuthFailure)?.endsSession == true { report(error) }
            if more { sharedMore.insert(key) }
        }
    }

    /// Once a session, when a picker or the composer first needs them; a failure leaves the list empty and allows a retry.
    /// Asks the server for `conversation`'s commands matching what's typed after "/", as Google Chat does on each key
    /// (the full list comes a page at a time). A bare "/" starts over, so added or removed apps show; each other query
    /// is asked once and its commands join the list.
    func loadSlashCommands(_ conversation: ConversationID, query: String) async {
        if query.isEmpty { slashQueries[conversation] = [] }
        guard slashQueries[conversation, default: []].insert(query).inserted else { return }
        do {
            let toApp = conversations.first { $0.id == conversation }?.app != nil
            let found = try await backend.slashCommands(in: conversation, matching: query, toApp: toApp)
            let known = query.isEmpty ? [] : slashCommands[conversation] ?? []
            slashCommands[conversation] = known + found.filter { new in !known.contains { $0.appID == new.appID && $0.id == new.id } }
        } catch {
            slashQueries[conversation]?.remove(query)
            if (error as? AuthFailure)?.endsSession == true { report(error) }
        }
    }
    func loadCustomEmoji() async {
        if let customEmojiLoad { return await customEmojiLoad.value }
        let load = Task {
            do { customEmoji = try await backend.customEmojis() } catch {
                if case .http(403)? = error as? AuthFailure { return }   // personal accounts have none: don't ask again
                customEmojiLoad = nil
                if (error as? AuthFailure)?.endsSession == true { report(error) }
            }
        }
        customEmojiLoad = load
        await load.value
    }

    func loadMembers(_ conversation: ConversationID) async {
        guard members[conversation] == nil else { return }
        await reloadMembers(conversation)
    }
    /// The list on screen stays until the new one arrives.
    private func reloadMembers(_ conversation: ConversationID) async {
        guard !memberLoads.contains(conversation) else { return }
        memberLoads.insert(conversation); defer { memberLoads.remove(conversation) }
        if let people = try? await backend.members(of: conversation), !people.isEmpty {
            members[conversation] = people
            roles[conversation] = await backend.roles(in: conversation)
        }
    }
    /// Unknown (nothing offered) when the server doesn't answer.
    func loadPermissions(_ conversation: ConversationID) async {
        guard conversations.first(where: { $0.id == conversation })?.kind != .direct else { return }
        if let allowed = try? await backend.permissions(in: conversation) { permissions[conversation] = allowed }
    }
    /// Adds files to the draft; ones Google Chat would refuse (folders, empty, over 200 MB) are reported and left out.
    func attach(_ urls: [URL], conversation: String, thread: String?) {
        let scope = key(conversation, thread)
        var refused: [String] = []
        for url in urls {
            do { draftAttachments[scope, default: []].append(try .localFile(at: url)) } catch { refused.append(error.localizedDescription) }
        }
        if !refused.isEmpty { error = refused.joined(separator: "\n") }
    }
    func detach(_ attachment: Attachment, conversation: String, thread: String?) {
        draftAttachments[key(conversation, thread)]?.removeAll { $0 == attachment }
    }
    func send(conversation: String, thread: String? = nil) async {
        let scope = key(conversation, thread)
        let (text, formatting) = Self.trimmed(drafts[scope, default: ""], draftFormatting[scope] ?? [])
        if let editingID = editing[scope] {
            guard !text.isEmpty else { return }
            do { try await backend.edit(editingID, text: text, formatting: formatting); finishEdit(scope) }
            catch { report(error) }
            return
        }
        let files = draftAttachments[scope] ?? []
        guard !text.isEmpty || !files.isEmpty || quoting[scope]?.forwardedFrom != nil else { return }   // a forward needs no note
        setDraft("", conversation: conversation, thread: thread)
        draftAttachments[scope] = nil
        let quote = quoting.removeValue(forKey: scope)
        // The send names the draft, and the server drops it; nothing is left to save here.
        draftTimers.removeValue(forKey: scope)?.cancel(); draftEdits[scope] = nil
        let draft = serverDrafts.removeValue(forKey: scope)?.id
        if let draft { spentDrafts.insert(draft) }
        draftSends[scope, default: 0] += 1
        await sendNew(text, formatting: formatting, attachments: files, quote: quote, serverDraft: draft, conversation: conversation, thread: thread)
        sent?(conversation)
    }
    /// After a send from the composer: the app tells Siri who I message (never what), so it learns my usual recipients.
    @ObservationIgnored var sent: ((ConversationID) -> Void)?
    /// Fetches a picked GIF from its CDN; injectable for tests.
    var download: (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    /// Sends a picked GIF on its own, quoting the message being replied to, as Google Chat does; the local echo shows it as an
    /// image attachment. Sent as an upload: the server drops a client-made URL chip for GIPHY links and stores an empty message.
    func sendGif(_ gif: Attachment, conversation: String, thread: String? = nil) async {
        guard let url = gif.url else { return }
        do {
            let name = (gif.name.isEmpty ? "GIF" : gif.name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name + ".gif")
            try await download(url).write(to: file)
            await sendNew("", attachments: [try .localFile(at: file)], quote: quoting.removeValue(forKey: key(conversation, thread)),
                          conversation: conversation, thread: thread)
        } catch { report(error) }
    }
    /// Sends a recording on its own (quoting the message being replied to), as Google Chat does: an upload named and typed like its own recordings, with the voice metadata.
    func sendVoice(_ file: URL, duration: TimeInterval, waveform: [Int], conversation: String, thread: String? = nil) async {
        let voice = Attachment(name: file.lastPathComponent, contentType: Voice.contentType, kind: .voice, url: file,
                               voice: Voice(duration: duration, waveform: waveform))
        await sendNew("", attachments: [voice], quote: quoting.removeValue(forKey: key(conversation, thread)), conversation: conversation, thread: thread)
    }
    /// A notification's inline reply: sent without touching the draft, and the conversation counts as read, as Messages does.
    func reply(_ text: String, conversation: ConversationID, thread: ThreadID?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await sendNew(text, conversation: conversation, thread: thread)
        await markRead(conversation)
    }
    /// Shortcuts' and Siri's Send Message: plain text to one of my conversations, as if typed in its composer. True once
    /// Google has it; false for empty text, a conversation I'm not in, or a send that failed (left as failed in the timeline).
    func sendText(_ text: String, to conversation: ConversationID) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, conversations.contains(where: { $0.id == conversation }) else { return false }
        let id = await sendNew(text, conversation: conversation, thread: nil)
        return !messages.contains { $0.id == id && $0.delivery == .failed }
    }
    /// Returns once the first conversation list is in (at most 15 s): an action that launched Parley waits for it.
    func listed() async {
        for _ in 0..<150 where !listedOnce { try? await Task.sleep(for: .milliseconds(100)) }
    }
    @discardableResult
    private func sendNew(_ text: String, formatting: [TextStyleRange] = [], attachments: [Attachment] = [], quote: QuotedMessage? = nil,
                         serverDraft: String? = nil, conversation: String, thread: String?) async -> MessageID {
        if thread == nil, detached.contains(conversation) { await returnToNewest(conversation) }   // a send lands at the bottom, as on the web
        let pending = Message(id: "local-\(UUID())", conversationID: conversation, threadID: thread, sender: me, text: text,
                              delivery: .pending, attachments: attachments, formatting: formatting, quote: quote)
        upsert(pending)
        await deliver(pending, serverDraft: serverDraft)
        return pending.id
    }
    /// The draft without surrounding whitespace, its ranges shifted and clipped to match (UTF-16 offsets).
    static func trimmed(_ text: String, _ formatting: [TextStyleRange]) -> (String, [TextStyleRange]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let found = text.range(of: trimmed) else { return (trimmed, []) }
        let lead = text.utf16.distance(from: text.startIndex, to: found.lowerBound), count = trimmed.utf16.count
        return (trimmed, formatting.compactMap { range in
            let start = max(0, range.start - lead), end = min(count, range.start + range.length - lead)
            return end > start ? TextStyleRange(style: range.style, start: start, length: end - start) : nil
        })
    }
    /// Uploads the echo's local files first, keeping each finished upload on the echo so a retry only redoes what failed.
    // ponytail: a retry no longer names the draft; if the send never reached Google, its draft comes back at the next launch.
    private func deliver(_ pending: Message, serverDraft: String? = nil) async {
        var pending = pending
        // Google refuses a quote of a deleted message (HTTP 404) however often it's sent: the message goes without it.
        if let quoted = pending.quote?.id, messages.contains(where: { $0.id == quoted && $0.tombstone }) { pending.quote = nil }
        do {
            for (index, file) in pending.attachments.enumerated() where file.isLocalFile && file.uploadToken == nil {
                pending.attachments[index] = try await backend.upload(file, to: pending.conversationID, thread: pending.threadID)
                upsert(pending)
            }
            let sent = try await backend.send(MessageDraft(text: pending.text, localID: pending.id, formatting: pending.formatting,
                                                           uploads: pending.attachments.filter(\.isLocalFile), quoting: pending.quote,
                                                           serverDraftID: serverDraft),
                                               to: pending.conversationID, thread: pending.threadID)
            messages.removeAll { $0.id == pending.id }; upsert(sent)
            // A command that opens a dialog: the app's dialog for the command's message, as Google Chat asks for it.
            if let command = pending.formatting.lazy.compactMap({ if case .slashCommand(let command) = $0.style { command } else { nil } }).first,
               command.opensDialog {
                await openDialog(DialogContext(message: sent.id, app: command.appID), app: command.appName, in: sent.conversationID, action: nil, inputs: [])
            }
        } catch {
            log.error("send failed: \(ConnectionDiagnostics.redact(String(describing: error)), privacy: .public)")
            var failed = pending; failed.delivery = .failed; upsert(failed)
            _ = endedSession(error)
        }
        persist()
    }
    func retry(_ message: Message) async {
        guard message.delivery == .failed else { return }
        var pending = message; pending.delivery = .pending; upsert(pending)
        await deliver(pending)
    }
    /// The message `conversation`'s composer (or its `thread`'s) is editing.
    func editingID(_ conversation: ConversationID, thread: ThreadID?) -> MessageID? { editing[key(conversation, thread)] }
    /// Leaving what the main window shows ends the edits in its composers (the conversation's and its thread pane's) and
    /// clears their text, which is the message's, not a draft. A thread in its own window keeps its edit.
    private func endMainWindowEdits() {
        guard let room = selectedID else { return }
        for scope in [key(room, nil)] + (threadID.map { [key(room, $0)] } ?? []) { finishEdit(scope) }
    }
    /// Esc in an editing composer: the edit is dropped and the draft is back.
    func endEdit(conversation: ConversationID, thread: ThreadID?) { finishEdit(key(conversation, thread)) }
    /// Ends `scope`'s edit and gives back the draft it borrowed the composer from. The draft's sync state never changed
    /// (an edit is no draft), so nothing is saved or deleted on Google.
    private func finishEdit(_ scope: String) {
        guard editing.removeValue(forKey: scope) != nil else { return }
        let held = heldDrafts.removeValue(forKey: scope)
        drafts[scope] = held?.text ?? ""; draftFormatting[scope] = held?.formatting
        persist()
    }
    func edit(_ message: Message) {
        guard message.sender.id == me.id, message.delivery == .sent else { return }
        let scope = key(message.conversationID, message.threadID)
        if editing[scope] == nil { heldDrafts[scope] = (drafts[scope] ?? "", draftFormatting[scope]) }
        editing[scope] = message.id
        quoting[key(message.conversationID, message.threadID)] = nil
        setDraft(message.text, formatting: message.formatting, conversation: message.conversationID, thread: message.threadID)
    }
    /// Quote-replies to `message` from its own composer (the conversation's, or its thread's); ends an edit there.
    /// Without a server update time it names the create time.
    func quote(_ message: Message) {
        guard message.delivery == .sent, !message.isSystem, !message.tombstone else { return }
        finishEdit(key(message.conversationID, message.threadID))
        quoting[key(message.conversationID, message.threadID)] = QuotedMessage(
            sender: message.sender.name, text: QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments), id: message.id,
            lastUpdateMicros: message.lastUpdateMicros ?? Int64((message.createdAt.timeIntervalSince1970 * 1_000_000).rounded()),
            media: message.attachments.first { $0.kind == .image || $0.kind == .video })
    }
    /// Send to Parley: the text joins `conversation`'s draft on a line of its own and the files attach to it; nothing is sent.
    func share(_ shared: Shared, to conversation: ConversationID) {
        let scope = key(conversation, nil), draft = drafts[scope] ?? ""
        if !shared.text.isEmpty {
            setDraft(draft.isEmpty ? shared.text : draft + "\n" + shared.text, formatting: draftFormatting[scope] ?? [], conversation: conversation, thread: nil)
        }
        attach(shared.files, conversation: conversation, thread: nil)
    }
    /// Forward…: `message` waits above `destination`'s composer, as in Google Chat, and goes with the next send there.
    func forward(_ message: Message, to destination: ConversationID) {
        guard message.delivery == .sent, !message.isSystem else { return }
        var forward = QuotedMessage(sender: message.sender.name, text: QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments),
                                    id: message.id, lastUpdateMicros: message.lastUpdateMicros ?? Int64((message.createdAt.timeIntervalSince1970 * 1_000_000).rounded()))
        forward.forwardedFrom = conversations.first { $0.id == message.conversationID }?.name ?? "a conversation"
        forward.media = message.attachments.first { $0.kind == .image || $0.kind == .video }
        quoting[key(destination, nil)] = forward
    }
    func delete(_ message: Message) async {
        do { try await backend.delete(message.id) } catch { report(error) }
    }
    /// Siri's edit: one of my sent messages gets new plain text. False when it isn't mine or Google refused it.
    func editText(of id: MessageID, to text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let message = messages.first(where: { $0.id == id }), message.sender.id == me.id, message.delivery == .sent else { return false }
        do { try await backend.edit(id, text: text, formatting: []); return true }
        catch { log.error("edit failed: \(String(describing: error), privacy: .public)"); return false }
    }
    /// Siri's unsend: one of my sent messages is deleted for everyone. False when it isn't mine or Google refused it.
    func unsend(_ id: MessageID) async -> Bool {
        guard let message = messages.first(where: { $0.id == id }), message.sender.id == me.id, message.delivery == .sent else { return false }
        do { try await backend.delete(id); return true }
        catch { log.error("unsend failed: \(String(describing: error), privacy: .public)"); return false }
    }
    /// Siri's "mark this as read/unread": read clears the conversation; unread starts at the message, as its menu does.
    func setRead(_ read: Bool, _ message: Message) async {
        if read { await markRead(message.conversationID) } else { await markUnread(from: message) }
    }
    /// `custom`: a custom emoji picked for the reaction; a pill's own custom emoji goes back whole.
    func react(_ emoji: String, custom: CustomEmoji? = nil, to message: Message) async {
        let existing = message.reactions.first { $0.emoji == emoji }
        let present = !(existing?.people.contains(me.id) ?? false)
        do { try await backend.setReaction(emoji, custom: existing?.custom ?? custom, on: message.id, present: present) } catch { report(error) }
    }
    /// Errors stay with the caller: a missing thumbnail shouldn't raise the store-wide error.
    /// A file not sent yet (the local echo) is read from disk.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data {
        if let file = attachment.url, file.isFileURL { return try await Task.detached { try Data(contentsOf: file, options: .mappedIfSafe) }.value }
        return try await backend.attachmentData(attachment, thumbnail: thumbnail)
    }
    /// Messages in this timeline still uploading their files; the composer says so.
    func uploading(_ conversation: String, thread: String? = nil) -> Int {
        timeline(conversation, thread: thread).filter { $0.delivery == .pending && $0.attachments.contains { $0.isLocalFile && $0.uploadToken == nil } }.count
    }
    func markRead(_ id: String) async {
        notifier?.clear(conversation: id)
        // In the background, and tried again on the next visit: a refusal is for the log, not an alert.
        do { try await backend.markRead(id) } catch { log.error("mark read failed: \(String(describing: error), privacy: .public)") }
    }
    func setPinned(_ pinned: Bool, _ id: ConversationID) async {
        await change(id, \.pinned, to: pinned) { try await self.backend.setPinned(pinned, conversation: id) }
    }
    func setMuted(_ muted: Bool, _ id: ConversationID) async {
        await change(id, \.muted, to: muted) { try await self.backend.setMuted(muted, conversation: id) }
    }
    func setNotificationLevel(_ level: NotificationLevel, _ id: ConversationID) async {
        guard let room = conversations.first(where: { $0.id == id }) else { return }
        await change(id, \.notificationLevel, to: level) { try await self.backend.setNotificationLevel(level, muted: room.muted, conversation: id) }
    }
    /// Conversations marked unread from a message while open: not read again until left and returned to.
    @ObservationIgnored private var heldUnread: Set<ConversationID> = []
    /// "Mark as unread" on a message: unread from it on, the conversation's, or for a reply its thread's on Home.
    func markUnread(from message: Message) async {
        if let thread = message.threadID {
            if let i = homeThreads.firstIndex(where: { $0.id == thread }) { homeThreads[i].unread = true }
            do { try await backend.markUnread(from: message) } catch { report(error) }
            return
        }
        let count = max(1, messages.filter { $0.conversationID == message.conversationID && $0.threadID == nil
            && $0.createdAt >= message.createdAt && $0.sender.id != me.id }.count)
        heldUnread.insert(message.conversationID)
        await change(message.conversationID, \.unread, to: count) { try await self.backend.markUnread(from: message) }
    }
    func markUnread(_ id: ConversationID) async {
        guard let room = conversations.first(where: { $0.id == id }) else { return }
        await change(id, \.unread, to: max(room.unread, 1)) { try await self.backend.markUnread(id) }
    }
    /// Shown at once and sent; a refusal puts back only this field (others may have changed meanwhile) and says why.
    private func change<Value>(_ id: ConversationID, _ field: WritableKeyPath<Conversation, Value>, to value: Value,
                               send: () async throws -> Void) async {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let before = conversations[i][keyPath: field]
        conversations[i][keyPath: field] = value; persist()
        do { try await send() } catch {
            if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i][keyPath: field] = before }
            report(error); persist()
        }
    }
    func leave(_ id: ConversationID) async { await removeFromSidebar(id) { try await self.backend.leave(id) } }
    func hide(_ id: ConversationID) async {
        guard var room = conversations.first(where: { $0.id == id }) else { return }
        await removeFromSidebar(id) { try await self.backend.setHidden(true, conversation: id) }
        guard !conversations.contains(where: { $0.id == id }), !hidden.contains(where: { $0.id == id }) else { return }   // refused, or pushed meanwhile
        room.hidden = .now
        hidden.insert(room, at: 0)
    }
    /// Back in the sidebar at once; a refusal hides it again and says why.
    func unhide(_ id: ConversationID) async {
        guard var room = hidden.first(where: { $0.id == id }) else { return }
        let hiddenAt = room.hidden
        room.hidden = nil
        apply(.conversationUpserted(room)); persist()
        do { try await backend.setHidden(false, conversation: id) } catch {
            room.hidden = hiddenAt
            apply(.conversationUpserted(room)); persist()
            report(error)
        }
    }
    /// Gone from the sidebar at once; a refusal puts it back where it was.
    private func removeFromSidebar(_ id: ConversationID, send: () async throws -> Void) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let room = conversations[index]
        apply(.conversationRemoved(id))
        do { try await send() } catch {
            if !conversations.contains(where: { $0.id == id }) { conversations.insert(room, at: min(index, conversations.count)) }
            report(error); persist()
        }
    }
    func rename(_ id: ConversationID, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let room = conversations.first(where: { $0.id == id }), room.name != name else { return }
        await change(id, \.name, to: name) { try await self.backend.updateProfile(id, name: name, emoji: nil) }
    }
    /// Description and guidelines go together, as Google Chat saves them; empty clears one.
    func updateDetails(_ id: ConversationID, description: String, guidelines: String) async {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let details = (trim(description).isEmpty ? nil : trim(description), trim(guidelines).isEmpty ? nil : trim(guidelines))
        guard let i = conversations.firstIndex(where: { $0.id == id }), (conversations[i].description, conversations[i].guidelines) != details else { return }
        let before = (conversations[i].description, conversations[i].guidelines)
        conversations[i].description = details.0; conversations[i].guidelines = details.1; persist()
        do { try await backend.updateDetails(id, description: details.0 ?? "", guidelines: details.1 ?? "") } catch {
            if let i = conversations.firstIndex(where: { $0.id == id }) { (conversations[i].description, conversations[i].guidelines) = before }
            report(error); persist()
        }
    }
    func setHistory(_ on: Bool, in id: ConversationID) async {
        await change(id, \.historyOff, to: !on) { try await self.backend.setHistory(on, in: id) }
    }
    /// My sidebar sections, shared with the web, in my order; empty until Google sends them.
    private(set) var sections: [SidebarSection] = []
    /// A new section after my others, with `conversation` moved into it, as web Chat's Move to a new section.
    func createSection(_ name: String, moving conversation: ConversationID?) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let last = sections.filter { $0.kind == .custom || $0.kind == .spaces }.map(\.position).max() ?? 2
        do {
            let made = try await backend.createSection(named: name, at: last + 1)
            // Google moves the sections from that place down by one.
            sections = sections.map { var section = $0; if section.position >= made.position { section.position += 1 }; return section } + [made]
            if let conversation { await moveConversation(conversation, to: made.key) }
        } catch { report(error) }
    }
    func renameSection(_ section: SidebarSection, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[i].name = name
        do { try await backend.renameSection(section, to: name) } catch { sections[i].name = section.name; report(error) }
    }
    /// One place up or down among the sections below Shortcuts; Google renumbers the rest, as here.
    func moveSection(_ section: SidebarSection, up: Bool) async {
        let ordered = sections.sorted { $0.position < $1.position }
        guard let i = ordered.firstIndex(where: { $0.id == section.id }), case let j = up ? i - 1 : i + 1,
              ordered.indices.contains(j), ordered[j].kind != .shortcuts else { return }
        let before = sections, target = ordered[j].position
        sections = sections.map { var other = $0
            if other.id == section.id { other.position = target } else if other.id == ordered[j].id { other.position = section.position }
            return other }
        do { try await backend.moveSection(section, to: target) } catch { sections = before; report(error) }
    }
    /// Its conversations go back to their default sections, as Google Chat does.
    func deleteSection(_ section: SidebarSection) async {
        let before = (sections, conversations)
        sections.removeAll { $0.id == section.id }
        for i in conversations.indices where conversations[i].section == section.key { conversations[i].section = nil }
        do { try await backend.deleteSection(section) } catch { (sections, conversations) = before; report(error) }
        persist()
    }
    /// Into one of my sections (its key), or back to its default one (nil).
    func moveConversation(_ id: ConversationID, to section: String?) async {
        let previous = conversations.first { $0.id == id }?.section
        guard previous != section else { return }
        await change(id, \.section, to: section) { try await self.backend.moveConversation(id, to: section, from: previous) }
    }
    /// People I blocked: their messages show as blocked, their DM leaves the sidebar.
    private(set) var blockedPeople: Set<PersonID> = []
    func loadBlocked() async { if let people = try? await backend.blockedPeople() { blockedPeople = Set(people) } }
    /// The 1:1 DM with someone, if the sidebar has one.
    func dm(with person: PersonID) -> Conversation? {
        conversations.first { $0.kind == .direct && $0.app == nil && partner(in: $0) == person }
    }
    /// Blocks a person, as Google Chat's Block and report: their DM leaves the sidebar at once; a refusal puts it back.
    func block(person: PersonID, report toGoogle: Bool) async {
        let dm = dm(with: person)
        blockedPeople.insert(person)
        if let dm { apply(.conversationRemoved(dm.id)) }
        do { try await backend.setBlocked(true, person: person, dm: dm?.id, report: toGoogle) } catch {
            blockedPeople.remove(person)
            if let dm, !conversations.contains(where: { $0.id == dm.id }) { conversations.append(dm) }
            report(error)
        }
        persist()
    }
    func unblock(person: PersonID) async {
        blockedPeople.remove(person)
        do { try await backend.setBlocked(false, person: person, dm: dm(with: person)?.id, report: false) } catch { blockedPeople.insert(person); report(error) }
        await loadBlocked()
    }
    func blockSpace(_ id: ConversationID, report toGoogle: Bool) async {
        await removeFromSidebar(id) { try await self.backend.setBlocked(true, space: id, report: toGoogle) }
    }
    func blockedSpaces() async throws -> [BlockedSpace] { try await backend.blockedSpaces() }
    /// A person's name from anything loaded: conversations, member lists, messages.
    func anyName(of person: PersonID) -> String {
        let known = conversations.flatMap(\.members) + members.values.flatMap { $0 } + messages.map(\.sender)
        return known.first { $0.id == person && $0.name != "Unknown" }?.name ?? "Someone"
    }
    func unblockSpace(_ id: ConversationID) async {
        do { try await backend.setBlocked(false, space: id, report: false) } catch { report(error) }
    }
    /// A blocked person's message as the timeline shows it: what they sent stays hidden, as Google Chat hides it.
    static func blockedView(_ message: Message) -> Message {
        var shown = message
        shown.text = "Message from a blocked person"
        shown.formatting = [TextStyleRange(style: .italic, start: 0, length: (shown.text as NSString).length)]
        shown.attachments = []; shown.quote = nil
        return shown
    }
    /// Errors stay with the caller's sheet.
    func report(_ message: Message, reason: ReportReason, explanation: String) async throws {
        try await backend.report(message, reason: reason, explanation: explanation)
    }
    /// Each member's role in a space, read with its members.
    private(set) var roles: [ConversationID: [PersonID: MemberRole]] = [:]
    func setRole(_ role: MemberRole, of person: PersonID, in id: ConversationID) async {
        let before = roles[id]?[person]
        roles[id, default: [:]][person] = role
        do { try await backend.setRole(role, of: person, in: id) } catch { roles[id]?[person] = before; report(error) }
    }
    func setEmoji(_ emoji: String, _ id: ConversationID) async {
        await change(id, \.emoji, to: emoji) { try await self.backend.updateProfile(id, name: nil, emoji: emoji) }
    }
    /// The roster is read again afterwards: a space lists invited people only once they join.
    func addMembers(_ people: [Person], to id: ConversationID) async {
        guard !people.isEmpty else { return }
        do { try await backend.addMembers(people.map(\.id), to: id) } catch { report(error); return }
        await reloadMembers(id)
    }
    /// Off the roster at once; a refusal puts them back.
    func removeMember(_ person: PersonID, from id: ConversationID) async {
        let before = members[id]
        members[id]?.removeAll { $0.id == person }
        do { try await backend.removeMember(person, from: id) } catch { members[id] = before; report(error) }
    }
    /// A shortcut's messages, newest first; Starred drops a message as soon as it is unstarred.
    func shortcutMessages(_ shortcut: Shortcut) -> [Message] {
        (shortcutLists[shortcut] ?? []).filter { shortcut != .starred || $0.starred }
    }
    /// Shows a sidebar shortcut in place of the conversation, freshly loaded.
    func openShortcut(_ shortcut: Shortcut, recording: Bool = true) async {
        if recording { visit(.shortcut(shortcut)) }
        endMainWindowEdits()
        self.shortcut = shortcut; threadID = nil; info = false
        shortcutCursors[shortcut] = nil
        await loadShortcut(shortcut)
    }
    /// The first page, or (`more`) the next one while the server has more. One request at a time per shortcut.
    func loadShortcut(_ shortcut: Shortcut, more: Bool = false) async {
        let scope = "shortcut/\(shortcut.rawValue)"
        guard shortcut != .home else { return }   // built from the conversations and messages already held; see `homeRows`
        guard shortcut != .drafts else { return }   // the composers' drafts; see `draftList`
        guard !loading.contains(scope), !more || shortcutCursors[shortcut] != nil else { return }
        loading.insert(scope); defer { loading.remove(scope) }
        do {
            let page = try await backend.shortcut(shortcut, cursor: more ? shortcutCursors[shortcut] : nil)
            let known = more ? shortcutLists[shortcut] ?? [] : [], ids = Set(known.map(\.id))
            shortcutLists[shortcut] = known + page.messages.filter { !ids.contains($0.id) }
            shortcutCursors[shortcut] = page.cursor
        } catch { report(error) }
    }
    /// Home, as Google Chat's: the conversations with activity, each with its newest timeline message held, and the threads
    /// it lists, each with its newest reply; most recent first. A conversation is ordered by the later of the server's
    /// activity time and that message, so a message pushed since moves it up. `unreadOnly` and `threadsOnly` are web's
    /// "Unread" switch and "Thread" filter.
    func homeRows(unreadOnly: Bool = false, threadsOnly: Bool = false) -> [HomeRow] {
        var newest: [ConversationID: Message] = [:]
        for message in messages where !message.isSystem && message.threadID == nil && newest[message.conversationID].map({ message.createdAt > $0.createdAt }) ?? true {
            newest[message.conversationID] = message
        }
        let rooms = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = homeThreads.compactMap { thread in rooms[thread.conversationID].map { HomeRow(room: $0, last: thread.latest, thread: thread, time: thread.time) } }
        let heads = Set(homeThreads.map(\.id))
        let roomRows = threadsOnly ? [] : conversations.compactMap { room -> HomeRow? in
            // As Google Chat: a conversation whose newest message starts a thread shown here appears only as that thread.
            if let last = newest[room.id], heads.contains(last.id) { return nil }
            let time = max(room.activity ?? .distantPast, newest[room.id]?.createdAt ?? .distantPast)
            return time == .distantPast ? nil : HomeRow(room: room, last: newest[room.id], time: time)
        }
        return (roomRows + threads).filter { !unreadOnly || $0.unread }.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time > $1.element.time }.map(\.element)
    }
    /// A Home thread row: Home stays on screen and the thread opens in the thread pane beside it, at its newest reply.
    /// The conversation itself is not opened or marked read.
    // ponytail: the thread is read only here; the server's topic read state is not written (set_topic_unread_timestamp-style).
    func openHomeThread(_ thread: HomeThread) async {
        endMainWindowEdits()
        shortcut = .home; selectedID = thread.conversationID; info = false
        if let i = homeThreads.firstIndex(where: { $0.id == thread.id }) { homeThreads[i].unread = false }
        await openThread(thread.id, in: thread.conversationID)
        highlightedID = thread.latest.id
        await watchOpen()
    }
    /// A Home row's newest page, when the server reports activity after the newest message held (or none is held).
    /// Waits for the account: before connecting, Home lists the cached conversations, which may be another account's.
    func loadPreview(_ id: ConversationID) async {
        guard !me.id.isEmpty, let room = conversations.first(where: { $0.id == id }) else { return }
        let last = messages.lazy.filter { $0.conversationID == id && !$0.isSystem }.map(\.createdAt).max()
        // A second of slack: the server's sort time can trail the message's own time by a little.
        if let last, (room.activity ?? .distantPast) <= last.addingTimeInterval(1) { return }
        await load(id, quietly: true)
    }
    /// A shortcut's message in its conversation (and thread), highlighted.
    func showInChat(_ message: Message) async {
        shortcut = nil
        guard conversations.contains(where: { $0.id == message.conversationID }) else { await jump(message); return }
        await select(message.conversationID)
        await show(message.id, in: message.conversationID)
    }
    /// Starred or unstarred everywhere it shows at once; a refusal puts it back and says why.
    /// The account's do not disturb schedules, once Settings has asked for them.
    private(set) var dndSchedules: DndSchedules?
    func loadDndSchedules() async {
        do { dndSchedules = try await backend.dndSchedules(timeZone: TimeZone.current.identifier) } catch { report(error) }
    }
    /// Saves the whole set; on failure the old one stays.
    func saveDndSchedules(_ schedules: DndSchedules) async {
        let old = dndSchedules
        dndSchedules = schedules
        do { try await backend.setDndSchedules(schedules) } catch { dndSchedules = old; report(error) }
    }
    // The board: messages pinned for everyone in a conversation, as Google Chat's Board panel lists them.
    private(set) var pinned: [ConversationID: [Message]] = [:]
    func loadPinned(_ conversation: ConversationID) async {
        do {
            let list = try await backend.pinnedMessages(in: conversation)
            pinned[conversation] = list
            let ids = Set(list.map(\.id))
            for i in messages.indices where messages[i].conversationID == conversation && messages[i].pinned != ids.contains(messages[i].id) {
                messages[i].pinned.toggle()
            }
        } catch { log.error("board not loaded: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)") }
    }
    func setPinned(_ value: Bool, _ message: Message) async {
        func mark(_ value: Bool) {
            for i in messages.indices where messages[i].id == message.id { messages[i].pinned = value }
            guard var list = pinned[message.conversationID] else { return }
            list.removeAll { $0.id == message.id }
            if value { var added = message; added.pinned = true; list.insert(added, at: 0) }
            pinned[message.conversationID] = list
        }
        mark(value)
        do { try await backend.setPinned(value, on: message.id) } catch { mark(!value); report(error) }
    }
    func setStarred(_ starred: Bool, _ message: Message) async {
        func mark(_ value: Bool) {
            for i in messages.indices where messages[i].id == message.id { messages[i].starred = value }
            for (key, list) in shortcutLists { shortcutLists[key] = list.map { var m = $0; if m.id == message.id { m.starred = value }; return m } }
            if value, let list = shortcutLists[.starred], !list.contains(where: { $0.id == message.id }) {
                var added = message; added.starred = true
                shortcutLists[.starred] = (list + [added]).sorted { $0.createdAt > $1.createdAt }
            }
        }
        mark(starred)
        do { try await backend.setStarred(starred, on: message.id) } catch { mark(!starred); report(error) }
        persist()
    }
    /// Search results for `query` and the filters; ⌘F's conversation is a "said in" filter.
    func search(_ query: String, filters: SearchFilters = SearchFilters()) async {
        searchGeneration += 1
        let generation = searchGeneration
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty || !filters.isEmpty else { searchResults = []; return }   // chips alone search too
        do {
            let page = try await backend.searchMessages(query, filters: filters, cursor: nil)
            if generation == searchGeneration { searchResults = page.messages }
        } catch { if generation == searchGeneration { report(error) } }
    }
    /// File › New Chat asks the main window to open its palette.
    var newChatRequests = 0
    /// File › New Space asks the main window for its New Space sheet.
    var newSpaceRequests = 0
    /// Spaces someone invited me to, from the space directory; joining one accepts it.
    private(set) var invitations: [SpaceListing] = []
    @ObservationIgnored private var invitationsFetched: Date?
    /// Nothing announces a new invitation, so the directory is read again this often while Parley is in front.
    static let invitationsTTL: TimeInterval = 300
    /// Reads invitations from the space directory, at most once per `invitationsTTL` unless forced. A failed read keeps the last list.
    func refreshInvitations(force: Bool = false) async {
        guard force || invitationsFetched.map({ now().timeIntervalSince($0) >= Self.invitationsTTL }) ?? true else { return }
        invitationsFetched = now()
        // ponytail: the directory's first page only; page through it if invitations past it go missing.
        guard let listed = try? await backend.browseSpaces("") else { return }
        let inSidebar = Set(conversations.map(\.id))
        invitations = listed.filter { $0.invited && !inSidebar.contains($0.id) }
    }
    var forwarding: Message?   // Forward…: the message whose destination is being picked
    var sharing: Shared?       // Send to Parley: what waits for a conversation to be picked
    var searchRequest: SearchRequest?   // Shortcuts' Search Messages: the words the main window's search panel opens with
    // New conversations. Errors stay with the caller, which shows them where the search or action happened.
    func searchPeople(_ query: String) async throws -> [Person] { try await backend.searchPeople(query) }
    func browseSpaces(_ query: String) async throws -> [SpaceListing] { try await backend.browseSpaces(query) }
    /// Opens the DM with exactly these people: the sidebar's when there is one, else the server's (found or created).
    func message(_ people: [Person]) async throws {
        let ids = Set(people.map(\.id)).subtracting([me.id])
        guard !ids.isEmpty else { return }
        if let room = conversations.first(where: { $0.kind != .space && Set($0.members.map(\.id)).subtracting([me.id]) == ids }) {
            await select(room.id)
            return
        }
        await open(try await backend.directMessage(with: people.map(\.id).filter { $0 != me.id }))
    }
    /// Joins a space, or just opens it when it is already in the sidebar.
    func join(_ space: SpaceListing) async throws {
        if conversations.contains(where: { $0.id == space.id }) { await select(space.id); return }
        await open(try await backend.join(space))
        invitations.removeAll { $0.id == space.id }
    }
    /// A new space with me in it, opened at once; Google Chat asks for a name only. Errors stay with the caller's sheet.
    func createSpace(name: String, emoji: String?) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NewSpaceError.noName }
        await open(try await backend.createSpace(name: name, emoji: emoji))
    }
    enum NewSpaceError: LocalizedError {
        case noName
        var errorDescription: String? { "A space needs a name." }
    }
    /// Off the sidebar at once; a refusal puts it back.
    func deleteSpace(_ id: ConversationID) async { await removeFromSidebar(id) { try await self.backend.deleteSpace(id) } }
    private func open(_ room: Conversation) async {
        apply(.conversationUpserted(room))
        await select(room.id)
    }
    func jump(_ message: Message) async {
        if !conversations.contains(where: { $0.id == message.conversationID }) {
            // A search hit from a conversation the sidebar doesn't list yet.
            conversations.append(Conversation(id: message.conversationID, name: "Conversation", kind: .group, members: []))
        }
        if message.threadID != nil {
            await select(message.conversationID)
            await openThread(message)
        } else if selectedID != message.conversationID || shortcut != nil || !messages.contains(where: { $0.id == message.id }) {
            // The page around it, as web Chat opens a search result: among its neighbours, flashing once it's there.
            await open(message.conversationID, at: message.id)
        }
        // Still missing (a reply its thread didn't load, or a refused page): the search copy stands in.
        if !messages.contains(where: { $0.id == message.id }) { upsert(message) }
        highlightedID = message.id
    }
    /// Saves at most once every two seconds, with whatever is current by then: a busy room never starves the save.
    private func persist() {
        guard cache != nil, cacheTask == nil else { return }
        cacheTask = Task {
            try? await Task.sleep(for: .seconds(2))
            cacheTask = nil
            guard !Task.isCancelled else { return }
            await save()
        }
    }
    private func snapshot() -> LaunchSnapshot {
        let grouped = Dictionary(grouping: messages.filter { $0.delivery != .pending }, by: { key($0.conversationID, $0.threadID) })
        // A composer being edited holds the message's text; its draft is the one the edit put aside.
        var drafts = drafts, formatting = draftFormatting
        for (scope, held) in heldDrafts { drafts[scope] = held.text; formatting[scope] = held.formatting }
        return LaunchSnapshot(accountID: me.id.isEmpty ? cachedAccountID : me.id, conversations: conversations,
                              messages: grouped.values.flatMap { Array($0.sorted { $0.createdAt < $1.createdAt }.suffix(50)) },
                              selectedID: selectedID, drafts: drafts, draftFormatting: formatting, draftEdits: draftEdits, serverDrafts: serverDrafts,
                              homeThreads: homeThreads)
    }
    private func save() async {
        guard let cache else { return }
        let snapshot = snapshot()
        do { try await Task.detached { try cache.save(snapshot) }.value }
        catch { self.error = "Couldn’t save the launch cache: \(error.localizedDescription)" }
    }
    /// At quit: the pending save can't wait for its delay.
    func flush() {
        cacheTask?.cancel(); cacheTask = nil
        guard let cache else { return }
        try? cache.save(snapshot())
    }
}
