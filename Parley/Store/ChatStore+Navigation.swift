import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    func select(_ id: ConversationID, recording: Bool = true) async {
        await enter(id, recording: recording) {
            history.loaded.remove(key(id, nil))  // the newest page again, with anything the event stream missed
            await load(id)
        }
    }
    /// Opens a conversation at an old message, as web Chat opens a search result: the page around it instead of the newest.
    func open(_ id: ConversationID, at message: MessageID) async {
        await enter(id, recording: true) { await loadAround(message, in: id) }
    }
    /// Shows a conversation in the main window with the page `loadPage` brings, then reads it, unless the user moved on.
    private func enter(_ id: ConversationID, recording: Bool, loadPage: () async -> Void) async {
        if recording { visit(.conversation(id)) }
        endMainWindowEdits()
        navigation.selectedID = id
        navigation.setPane(nil) { $0.closeThread() }
        navigation.shortcut = nil
        heldUnread.removeAll()  // opening a conversation reads it, one marked unread from a message included
        await loadPage()
        guard openConversation == id else { return }  // moved on while it loaded: it stays unread
        await markRead(id)
        persist()
        await watchOpen()
        await refreshPresence()
    }
    /// A click on a quote: highlights the quoted message. One not loaded brings the page around it, as web Chat does.
    func showQuoted(_ id: MessageID, in conversation: ConversationID, window: ConversationID? = nil) async {
        if !history.messages.contains(where: { $0.id == id }) { await loadAround(id, in: conversation) }
        guard let quoted = history.messages.first(where: { $0.id == id }) else { return }
        if let thread = quoted.threadID, thread != navigation.pane(window).thread {
            await openThread(quoted, window: window)
        }
        history.highlightedID = id
    }
    /// "Show in Chat" on a shared item: its message highlighted, in its thread when it is a reply.
    func showShared(_ item: SharedContent.Item, in conversation: ConversationID) async {
        guard let id = item.messageID else { return }
        await show(id, in: conversation)
    }
    /// A link sent to Parley (`open -a Parley <url>`, a link router): its conversation opens once the first conversation
    /// list is in. One this account can't open says so rather than going back to the browser, which could send it straight back.
    func open(url: URL) async {
        guard listedOnce else {
            waitingLinks.append(url)
            return
        }
        guard let link = ChatLink(url) else {
            log.notice("not a Google Chat link: ignored")
            return
        }
        if !(await open(link)) { error = "This account isn't in the conversation that link goes to." }
    }
    /// A Google Chat link in a message: opens its conversation, and its message when it names one.
    /// Returns false when Parley doesn't know the conversation, for the caller to open the link elsewhere.
    func open(_ link: ChatLink) async -> Bool {
        guard let conversation = link.conversations.first(where: { id in rooms.conversations.contains { $0.id == id } })
        else { return false }
        guard let topic = link.topic else {
            await select(conversation)
            return true
        }
        let id = MessageID("\(conversation.rawValue)/\(topic)/\(link.message ?? topic)")
        // Straight to the page around it, as web Chat opens a message link, instead of the newest page first.
        let head = MessageID("\(conversation.rawValue)/\(topic)/\(topic)")
        if navigation.selectedID != conversation || navigation.shortcut != nil
            || !history.messages.contains(where: { $0.id == id || $0.id == head })
        {
            await open(conversation, at: id)
        }
        await show(id, in: conversation)
        return true
    }
    /// A message highlighted where it is: in its thread when it is a reply, else in the timeline, with the page around it
    /// when it isn't loaded.
    private func show(_ id: MessageID, in conversation: ConversationID) async {
        let parts = id.rawValue.split(separator: "/")  // <conversation>/<topic>/<message>: a reply's message differs from its topic
        if parts.count >= 2, parts[parts.count - 1] != parts[parts.count - 2] {
            await openThread(
                ThreadID(parts.dropLast().joined(separator: "/") + "/" + parts[parts.count - 2]), in: conversation)
            history.highlightedID = id
            return
        }
        await showQuoted(id, in: conversation)
        // A thread's first message with replies opens the thread, as web Chat opens a link to one.
        if let head = history.messages.first(where: { $0.id == id }), head.threadID == nil, head.replyCount > 0 {
            await openThread(head)
        }
    }
    /// Whether a restored window's conversation is this account's; nil until the list has come.
    func hasConversation(_ id: ConversationID) -> Bool? {
        rooms.conversations.isEmpty ? nil : rooms.conversations.contains { $0.id == id }
    }
    // MARK: Back and forward, through the conversations and shortcuts opened (⌘[ and ⌘])

    typealias Place = NavigationModel.Place
    var canGoBack: Bool { !navigation.backPlaces.isEmpty || inGeminiSession }
    private var inGeminiSession: Bool { navigation.threadID != nil && selected?.app == .gemini }
    var canGoForward: Bool { navigation.canGoForward }
    private var place: Place? {
        if inGeminiSession, let id = navigation.selectedID, let thread = navigation.threadID {
            return .session(id, thread)
        }
        return navigation.shortcut.map(Place.shortcut) ?? navigation.selectedID.map(Place.conversation)
    }
    /// Opening a new place: the current one goes on the back list and the forward list ends, as in a browser.
    func visit(_ next: Place) { navigation.visit(next, from: place) }
    func goBack() async {
        guard let to = navigation.back(from: place) else {
            // A session opened with nothing before it (a notification at launch): Back still closes it to the home.
            if inGeminiSession, let place {
                navigation.forwardPlaces.append(place)
                navigation.setPane(nil) { $0.closeThread() }
            }
            return
        }
        await open(to)
    }
    func goForward() async {
        guard let to = navigation.forward(from: place) else { return }
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

    // MARK: Shortcuts, and jumping to a message

    /// A shortcut's messages, newest first; Starred drops a message as soon as it is unstarred.
    func shortcutMessages(_ shortcut: Shortcut) -> [Message] {
        (history.shortcutLists[shortcut] ?? []).filter { shortcut != .starred || $0.starred }
    }
    /// Shows a sidebar shortcut in place of the conversation, freshly loaded.
    func openShortcut(_ shortcut: Shortcut, recording: Bool = true) async {
        if recording { visit(.shortcut(shortcut)) }
        endMainWindowEdits()
        navigation.shortcut = shortcut
        navigation.setPane(nil) { $0.content = nil }
        history.shortcutCursors[shortcut] = nil
        await loadShortcut(shortcut)
    }
    /// The first page, or (`more`) the next one while the server has more. One request at a time per shortcut.
    func loadShortcut(_ shortcut: Shortcut, more: Bool = false) async {
        let scope = "shortcut/\(shortcut.rawValue)"
        guard shortcut != .home else { return }  // built from the conversations and messages already held; see `homeRows`
        guard shortcut != .drafts else { return }  // the composers' drafts; see `draftList`
        guard !history.loading.contains(scope), !more || history.shortcutCursors[shortcut] != nil else { return }
        history.loading.insert(scope)
        defer { history.loading.remove(scope) }
        do {
            let page = try await backend.shortcut(shortcut, cursor: more ? history.shortcutCursors[shortcut] : nil)
            let known = more ? history.shortcutLists[shortcut] ?? [] : []
            let ids = Set(known.map(\.id))
            history.shortcutLists[shortcut] = known + page.messages.filter { !ids.contains($0.id) }
            history.shortcutCursors[shortcut] = page.cursor
        } catch { report(error) }
    }
    /// A shortcut's message in its conversation (and thread), highlighted.
    func showInChat(_ message: Message) async {
        navigation.shortcut = nil
        guard rooms.conversations.contains(where: { $0.id == message.conversationID }) else {
            await jump(message)
            return
        }
        await select(message.conversationID)
        await show(message.id, in: message.conversationID)
    }
    func jump(_ message: Message) async {
        if !rooms.conversations.contains(where: { $0.id == message.conversationID }) {
            // A search hit from a conversation the sidebar doesn't list yet.
            rooms.conversations.append(
                Conversation(id: message.conversationID, name: "Conversation", kind: .group, members: []))
        }
        if message.threadID != nil {
            await select(message.conversationID)
            await openThread(message)
        } else if navigation.selectedID != message.conversationID || navigation.shortcut != nil
            || !history.messages.contains(where: { $0.id == message.id })
        {
            // The page around it, as web Chat opens a search result: among its neighbours, flashing once it's there.
            await open(message.conversationID, at: message.id)
        }
        // Still missing (a reply its thread didn't load, or a refused page): the search copy stands in.
        if !history.messages.contains(where: { $0.id == message.id }) { upsert(message) }
        history.highlightedID = message.id
    }
}
