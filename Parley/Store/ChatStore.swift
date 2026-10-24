import AppKit
import Foundation
import OSLog
import Observation
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

@MainActor @Observable
final class ChatStore {
    var connection: ConnectionState = .offline {
        // A session that ends while in use is first renewed silently (see `onSessionLost`); the banner shows meanwhile.
        didSet {
            if connection == .signedOut, oldValue != .signedOut, !me.id.rawValue.isEmpty {
                Task { await onSessionLost() }
            }
        }
    }
    @ObservationIgnored var onSessionLost: @MainActor () async -> Void = {}
    var error: String?
    // For Connection Diagnostics.
    var connectedSince: Date?
    var lastEventAt: Date?  // the last event from Google, not counting connection changes
    var reconnects = 0
    var searchResults: [Message] = []
    var homeUnreadOnly = false  // Home's filters, kept for the session
    var homeThreadsOnly = false
    /// My conversations and what the server said about them: sections, Home's threads, members, roles, permissions.
    private(set) var rooms = ConversationsModel()
    /// Custom emoji, the @ list's apps, people and Drive files, slash commands, card details and reactors, as the server answered.
    private(set) var lookups = LookupsModel()
    /// Each composer's draft, files, quote and edit, Google's copies of the drafts, and scheduled messages.
    private(set) var drafting = DraftsModel()
    /// The main window's conversation or shortcut, every window's side pane, and Back and Forward.
    private(set) var navigation = NavigationModel()
    /// The messages loaded and their pages' bookkeeping, shortcut lists, Threads lists and the highlighted message.
    private(set) var history = TimelineModel()
    @ObservationIgnored let backend: any ChatBackend
    @ObservationIgnored let cache: (any LaunchCaching)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored var cacheTask: Task<Void, Never>?
    @ObservationIgnored var cachedAccountID: PersonID?
    @ObservationIgnored var searchGeneration = 0
    private(set) var me = Person(id: "", name: "")
    /// Typing, availability, custom status and read receipts: everyone else's, from realtime events.
    private(set) var presence = PresenceModel()
    /// Mine, as the server last said; `OwnStatus.current(at:)` drops what has expired since.
    var ownStatus = OwnStatus()
    // Threads seen this session (loaded, pushed, or labelled while connected) plus Home's, which are the server's followed ones;
    // a reply in any other thread re-reads Home's (checkFollowed).
    var followed: Set<ThreadID> = []  // observed: the thread pane's bell shows it
    @ObservationIgnored var notifiedReactions: Set<String> = []  // message#person#emoji already announced
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    /// The clock typing, presence and throttles run on; tests replace it.
    @ObservationIgnored var now: () -> Date = { .now }
    static let unreadWindow: TimeInterval = 120  // matches NotificationPolicy's age guard
    /// Whether the user can see the window; read receipts follow it.
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { NSApplication.shared.isActive }
    /// Banners for pushed messages; nil (tests, previews) posts nothing.
    @ObservationIgnored var notifier: (any Notifier)?
    @ObservationIgnored var notificationSettings: @MainActor () -> NotificationSettings = { .current }
    /// Google Chat's web client creates a draft a few seconds into a pause and updates it when the user leaves the composer;
    /// the idle save is a safety net. Tests shorten both.
    @ObservationIgnored var draftPause: Duration = .seconds(3)
    @ObservationIgnored var draftIdle: Duration = .seconds(30)

    init(backend: any ChatBackend, cache: (any LaunchCaching)? = nil) {
        self.backend = backend
        self.cache = cache
        wireModels()
        if let snapshot = cache?.load() {
            cachedAccountID = snapshot.accountID
            rooms.conversations = snapshot.conversations
            history.messages = snapshot.messages
            navigation.selectedID = snapshot.selectedID
            drafting.text = snapshot.drafts
            drafting.formatting = snapshot.draftFormatting
            drafting.edits = snapshot.draftEdits
            drafting.server = snapshot.serverDrafts
            rooms.homeThreads = snapshot.homeThreads
            lookups.customEmoji = snapshot.customEmoji
        }
    }
    /// Deletes the pictures and files kept on disk for the signed-in account; the app sets it, tests replace it.
    @ObservationIgnored var clearDiskCaches: () -> Void = {}
    /// Shows the Dock badge, `badgeCount`. The store calls it, not a window, so it keeps up with every window closed.
    @ObservationIgnored var onBadge: (String?) -> Void = { _ in } {
        didSet {
            shownBadge = .none
            updateBadge()
        }
    }
    @ObservationIgnored private var shownBadge: String?? = .none
    @ObservationIgnored var waitingLinks: [URL] = []
    @ObservationIgnored var listedOnce = false
    @ObservationIgnored var followCheck: Task<Void, Never>?
    @ObservationIgnored var awaitingFollow: [Message] = []
    @ObservationIgnored private var coalesced: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var coalesceAgain: Set<String> = []
    @ObservationIgnored var followAsked = ContinuousClock.now
    // ponytail: in a busy space with replies in threads Home doesn't list, this reads the world every 5 s; listen for the
    // topic's own update if that load shows.
    /// Google lists a reply's thread a moment after pushing the reply, so the read right after a push can miss it.
    @ObservationIgnored var followRecheck: Duration = .seconds(5)
    var dialog: OpenDialog?
    /// A short note shown for a moment over the conversation (an app's "Poll started."); it fades after `toastDuration`.
    var toast: String? {
        didSet {
            toastFade?.cancel()
            if toast != nil { toastFade = fade(after: toastDuration) { $0.toast = nil } }
        }
    }
    @ObservationIgnored var toastDuration: Duration = .seconds(3)
    @ObservationIgnored private var toastFade: Task<Void, Never>?
    /// Opens links an app's answer asks for (its setup page); tests record them.
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Where Edit ▸ Undo takes back a quick change: the key window's, the one the user acted in. The app sets it, tests
    /// give their own; nil offers no undo.
    @ObservationIgnored var undoManager: @MainActor () -> UndoManager? = { nil }
    /// Where dismissed cards are remembered; tests use their own.
    @ObservationIgnored var defaults = UserDefaults.standard
    static let dismissedCardsKey = "dismissedCards"
    /// After a send from the composer: the app tells Siri who I message (never what), so it learns my usual recipients.
    @ObservationIgnored var sent: ((ConversationID) -> Void)?
    /// Fetches a picked GIF from its CDN; injectable for tests.
    var download: (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    /// Conversations marked unread from a message while open: not read again until left and returned to.
    @ObservationIgnored var heldUnread: Set<ConversationID> = []
    /// The account's do not disturb schedules, once Settings has asked for them.
    var dndSchedules: DndSchedules?
    /// File › New Chat asks the main window to open its palette.
    var newChatRequests = 0
    /// File › New Space asks the main window for its New Space sheet.
    var newSpaceRequests = 0
    var forwarding: Message?  // Forward…: the message whose destination is being picked
    var sharing: Shared?  // Send to Parley: what waits for a conversation to be picked
    var searchRequest: SearchRequest?  // Shortcuts' Search Messages: the words the main window's search panel opens with
}

extension ChatStore {
    /// No session, or it was lost before this launch connected: the welcome screen.
    var needsSignIn: Bool { connection == .signedOut && me.id.rawValue.isEmpty }
    /// The session ended while the app was in use: a banner over the conversations, which stay.
    var sessionExpired: Bool { connection == .signedOut && !me.id.rawValue.isEmpty }
    /// Another account connected: nothing of the previous one may show, be sent, or be cached. Clears every property in
    /// `accountState`; a test holds each stored property to one of the two lists.
    private func forgetAccount() {
        drafting.cancel()
        drafting = DraftsModel()
        navigation = NavigationModel()
        history.cancel()
        history = TimelineModel(highlightDuration: history.highlightDuration)
        followCheck?.cancel()
        followCheck = nil
        rooms = ConversationsModel()
        wireModels()
        updateBadge()  // the new models' changes go where the old ones' did; the badge counts no conversations
        searchResults = []
        notifiedReactions = []
        lookups.cancel()
        lookups = LookupsModel()
        presence = PresenceModel()
        ownStatus = OwnStatus()
        followed = []
        awaitingFollow = []
        listedOnce = false
        dialog = nil
        forwarding = nil
        heldUnread = []
        dndSchedules = nil
        coalesced.values.forEach { $0.cancel() }
        coalesced = [:]
        coalesceAgain = []
    }
    /// Leaving a composer (another conversation, shortcut or thread in the main window) saves its draft; a change to the
    /// conversations or Home's threads updates the Dock badge.
    private func wireModels() {
        navigation.left = { [weak self] in self?.saveDrafts() }
        rooms.listsChanged = { [weak self] in self?.updateBadge() }
    }
    /// What `forgetAccount` clears when another account connects.
    static let accountState: Set<String> = [
        "drafting", "lookups", "history", "followCheck", "rooms", "navigation",
        "searchResults",
        "notifiedReactions",
        "presence", "ownStatus",
        "followed", "awaitingFollow",
        "listedOnce",
        "dialog", "forwarding", "heldUnread", "dndSchedules", "coalesced", "coalesceAgain",
    ]
    /// What stays across accounts: the app's wiring, settings, timers and the connection, and requests the user made
    /// before the switch (a link to open, content to share, a search to run).
    static let appState: Set<String> = [
        "backend", "cache", "cachedAccountID", "me", "connection", "onSessionLost", "onBadge", "shownBadge", "error",
        "connectedSince", "lastEventAt",
        "reconnects", "homeUnreadOnly", "homeThreadsOnly", "eventTask", "cacheTask",
        "searchGeneration", "sweepTask", "now", "isAppActive", "notifier", "notificationSettings", "draftPause",
        "draftIdle",
        "waitingLinks", "followAsked", "followRecheck", "toast", "toastDuration", "toastFade", "openURL", "undoManager",
        "defaults", "sent",
        "download", "clearDiskCaches", "newChatRequests", "newSpaceRequests", "sharing", "searchRequest",
    ]
    /// After the user chose Sign Out: the account's chats leave this Mac (the launch cache, pictures and files; Google keeps
    /// them all), and its drafts stay, as the dialog says, for the next sign-in to the same account. A session that expired
    /// on its own keeps everything, so signing in again is quick.
    func signedOut() {
        let kept = (drafting.text, drafting.formatting, drafting.edits, drafting.server)
        forgetAccount()
        (drafting.text, drafting.formatting, drafting.edits, drafting.server) = kept
        me = Person(id: "", name: "")
        connection = .signedOut
        flush()
        clearDiskCaches()
    }
    /// Shows a failure to the user. Cancellation is not one: the work was superseded or no longer wanted.
    /// A lost session is not one either: it shows as the session-expired banner, which offers to sign in again.
    /// `undone`: a change shown at once and now put back (a pin, a mute, a role, a reaction), which says so in a note that
    /// fades rather than an alert to dismiss.
    func report(_ error: Error, undone: String? = nil) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || endedSession(error) { return }
        log.error("\(Redaction.redact(error.localizedDescription), privacy: .public)")
        if let undone { toast = "Couldn't \(undone). \(Self.plain(error))" } else { self.error = Self.plain(error) }
    }
    /// A failure in plain words: the usual network ones say what to do, not their error domain and code.
    static func plain(_ error: Error) -> String {
        switch error {
        case let url as URLError:
            switch url.code {
            case .notConnectedToInternet, .dataNotAllowed: "You're offline. Check your connection and try again."
            case .timedOut: "Google Chat didn't answer. Check your connection and try again."
            case .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .secureConnectionFailed:
                "The connection to Google Chat dropped. Try again."
            default: url.localizedDescription
            }
        case AuthFailure.http(let status): "Google Chat refused this (HTTP \(status))."
        default: error.localizedDescription
        }
    }
    func endedSession(_ error: Error) -> Bool {
        guard (error as? AuthFailure)?.endsSession == true else { return false }
        log.notice("Google no longer accepts the session: signed out")
        connection = .signedOut
        return true
    }
    var selected: Conversation? { navigation.selectedID.flatMap { conversation($0) } }
    /// The sidebar's conversation with this id, and where it is in `conversations`.
    func conversation(_ id: ConversationID) -> Conversation? { rooms.conversations.first { $0.id == id } }
    func conversationIndex(_ id: ConversationID) -> Int? { rooms.conversations.firstIndex { $0.id == id } }
    /// The conversation whose timeline is on screen: none while a shortcut is (Home keeps `selectedID` for its thread pane).
    var openConversation: ConversationID? { navigation.shortcut == nil ? navigation.selectedID : nil }
    private func updateBadge() {
        let count = badgeCount
        let label = count == 0 ? nil : String(count)
        if shownBadge != .some(label) {
            shownBadge = label
            onBadge(label)
        }
    }
    func key(_ conversation: ConversationID, _ thread: ThreadID?) -> String {
        "\(conversation.rawValue)/\(thread?.rawValue ?? "timeline")"
    }
    func start() async {
        if eventTask == nil {
            let events = backend.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    self?.apply(event)
                }
            }
        }
        if sweepTask == nil {  // Google Chat sweeps typists every 3 s; presence goes stale after 60 s
            sweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    sweepTyping()
                    if isAppActive() {
                        await refreshPresence()
                        await refreshInvitations()
                    }
                }
            }
        }
        do {
            let known = cachedAccountID ?? (me.id.rawValue.isEmpty ? nil : me.id)
            me = try await backend.connect()
            // A cache from a build that didn't record its account may be anyone's.
            if known.map({ $0 != me.id }) ?? !rooms.conversations.isEmpty { forgetAccount() }
            cachedAccountID = me.id
            try await refresh(reselect: true)
        } catch AuthFailure.signInRequired {
            connection = .signedOut
        } catch is CancellationError {  // superseded by a newer start, or its view went away: that one decides the state
        } catch {
            report(error)
            connection = .offline
        }
    }
    /// Replaces the conversation list (the server's, pin and mute included) and reloads the open conversation.
    /// A resync (`reselect: false`) keeps the open thread and edit and marks nothing read.
    func refresh(reselect: Bool = false) async throws {
        // Together, so Home never shows the new list with the old threads (a conversation flashing up as a plain row).
        let listed = try await backend.conversations()
        let threads = await backend.homeThreads()
        rooms.list(listed, threads: threads)
        rooms.sections = await backend.sidebarSections()
        followed.formUnion(threads.map(\.id))  // Home's threads are the server's followed ones
        // Alongside the open conversation's page, not before it: the blocked list hides messages, so it lands with them.
        async let blocked: Void = loadBlocked()
        let vanished = !rooms.conversations.contains(where: { $0.id == navigation.selectedID })
        if vanished { navigation.selectedID = rooms.conversations.first?.id }
        if let open = navigation.selectedID {
            if reselect || vanished {
                // A shortcut on screen (Home at launch) stays: the conversation opens, and is read, only when chosen.
                if navigation.shortcut == nil { await select(open) }
            } else {
                if !history.detached.contains(open) {  // an old message open stays open; paging down reaches the new ones
                    history.loaded.remove(key(open, nil))
                    await load(open)
                }
                if let threadID = navigation.threadID {
                    history.loaded.remove(key(open, threadID))
                    await load(open, thread: threadID)
                }
            }
        }
        await blocked
        _ = await listDrafts()
        await listScheduled()
        await refreshInvitations(force: true)  // after the conversation shows: the space directory is a slow read
        persist()
        if !listedOnce {
            listedOnce = true
            let links = waitingLinks
            waitingLinks = []
            for url in links { await open(url: url) }
        }
    }
    /// Work a burst of events asks for again and again (re-reading a list, marking read), where only the latest result
    /// counts: one run at a time per `key`, and calls during a run make one more run after it. Results never land out
    /// of order, and a burst costs two runs, not one per event.
    func coalesce(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        guard coalesced[key] == nil else {
            coalesceAgain.insert(key)
            return
        }
        coalesced[key] = Task {
            repeat {
                coalesceAgain.remove(key)
                await work()
            } while coalesceAgain.contains(key)
            coalesced[key] = nil
        }
    }
    func upsert(_ message: Message) {
        var message = message
        if message.attachments.contains(where: { $0.card?.dismiss != nil }),
            defaults.stringArray(forKey: Self.dismissedCardsKey)?.contains(message.id.rawValue) == true
        {
            message.attachments.removeAll { $0.card?.dismiss != nil }
        }
        history.put(message)
        // Following, as the server does it: a thread loaded as followed, or one I start, reply in or am @mentioned in.
        if message.following || message.sender.id == me.id || NotificationPolicy.mentions(message, me: me.id) {
            followed.insert(message.threadID ?? ThreadID(head: message.id))  // a message outside a thread may start one
        }
    }
    /// Returns once the first conversation list is in (at most 15 s): an action that launched Parley waits for it.
    func listed() async {
        for _ in 0..<150 where !listedOnce { try? await Task.sleep(for: .milliseconds(100)) }
    }
    /// A task that waits `duration`, then runs `clear` unless cancelled first: a highlight or note that fades.
    private func fade(after duration: Duration, _ clear: @escaping @MainActor (ChatStore) -> Void) -> Task<Void, Never>
    {
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            clear(self)
        }
    }
}
