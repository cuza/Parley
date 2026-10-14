import AppKit

/// Deterministic local demo. No Google requests or credentials.
actor FakeBackend: ChatBackend {
    static let me = Person(id: "me", name: "Dave", presence: .available)
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private var rooms: [Conversation]
    private var history: [Message]
    var failNextSend = false
    private(set) var sentDrafts: [MessageDraft] = []
    var failNextUpload = false
    private(set) var uploaded: [Attachment] = []   // every upload attempt
    private(set) var markedRead: [ConversationID] = []
    private(set) var historyRequests = 0
    private(set) var memberRequests: [ConversationID] = []
    private var signedOut = false
    private let latency: Duration

    /// `longHistory` adds that many varied messages to Engineering, served in pages after `latency`, for scroll tests.
    /// `manyConversations` adds that many more DMs and spaces (some with long names), for sidebar tests.
    /// `formattedThread` adds a DM whose one thread reply is a long bold-and-list answer, like an assistant's.
    init(longHistory: Int = 0, manyConversations: Int = 0, formattedThread: Bool = false, latency: Duration = .zero) {
        self.latency = latency
        let stream = AsyncStream<ChatEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        let maria = Person(id: "maria", name: "Maria Chen", presence: .available)
        let alex = Person(id: "alex", name: "Alex Rivera", presence: .away)
        rooms = [
            Conversation(id: "design", name: "Design studio", kind: .space, members: [Self.me, maria, alex], unread: 2, pinned: true),
            Conversation(id: "maria", name: maria.name, kind: .direct, members: [Self.me, maria], pinned: true),
            Conversation(id: "alex", name: alex.name, kind: .direct, members: [Self.me, alex], unread: 1),
            Conversation(id: "launch", name: "Launch crew", kind: .group, members: [Self.me, maria, alex]),
            Conversation(id: "general", name: "General", kind: .space, members: [Self.me, maria, alex]),
            Conversation(id: "engineering", name: "Engineering", kind: .space, members: [Self.me, alex], muted: true),
            Conversation(id: "notebook", name: "Notebook", kind: .direct, members: [Self.me, Self.notebook], unread: 1,
                         avatarURL: Self.notebookIcon, app: .bot)
        ]
        rooms += stride(from: 1, through: manyConversations, by: 1).map { i in
            let person = Person(id: "person\(i)", name: i % 7 == 0 ? "Person \(i) with a very long name that cannot fit in the sidebar" : "Person \(i)")
            return i.isMultiple(of: 2)
                ? Conversation(id: "space\(i)", name: "Space \(i)", kind: .space, members: [Self.me], unread: i % 5 == 0 ? i : 0,
                               emoji: i % 3 == 0 ? "🚀" : nil)
                : Conversation(id: "dm\(i)", name: person.name, kind: .direct, members: [Self.me, person], unread: i % 5 == 0 ? 1 : 0)
        }
        let now = Date.now
        history = [
            Message(id: "d1", conversationID: "design", sender: maria, text: "Morning! I’ve been thinking about how we make this feel more at home on the Mac.", createdAt: now.addingTimeInterval(-3600)),
            Message(id: "d2", conversationID: "design", sender: maria, text: "A little less chrome, a little more room for the conversation.", createdAt: now.addingTimeInterval(-3550), reactions: [Reaction(emoji: "✨", people: ["me", "alex"])], starred: true),
            Message(id: "d3", conversationID: "design", sender: Self.me, text: "Agreed. Compact sidebar, native text, and threads that stay out of the way.", createdAt: now.addingTimeInterval(-3300),
                    pinned: true),
            Message(id: "d4", conversationID: "design", sender: alex, text: "The keyboard shortcuts are the part I’m most excited about. ⌘K should get us anywhere \u{FFFD}", createdAt: now.addingTimeInterval(-900),
                    reactions: [Reaction(emoji: Self.shipIt.text, people: ["maria"], custom: Self.shipIt)], replyCount: 2,
                    formatting: [TextStyleRange(style: .customEmoji(Self.shipIt), start: 86, length: 1)]),
            Message(id: "r1", conversationID: "design", threadID: "d4", sender: maria, text: "Yes! And Escape to get right back to the conversation.", createdAt: now.addingTimeInterval(-800)),
            Message(id: "r2", conversationID: "design", threadID: "d4", sender: Self.me, text: "That’s the plan.", createdAt: now.addingTimeInterval(-750)),
            Message(id: "d6", conversationID: "design", sender: alex, text: "https://shipyard.example/pr/42", createdAt: now.addingTimeInterval(-1_200),
                    attachments: [Self.shipyardPreview]),
            Message(id: "d7", conversationID: "design", sender: maria, text: "¡Qué bien! ¿Lo probamos con el equipo el jueves?", createdAt: now.addingTimeInterval(-1_000),
                    translation: Translation(text: "Nice! Shall we try it with the team on Thursday?", from: "es")),
            Message(id: "d5", conversationID: "design", sender: maria, text: "Try sending a message, adding a reaction, or opening the thread above. This workspace is a local demo.", createdAt: now.addingTimeInterval(-300)),
            Message(id: "n1", conversationID: "notebook", sender: Self.notebook, text: "Maria Chen mentioned you in a comment in Launch plan",
                    createdAt: now.addingTimeInterval(-1_500), attachments: [Self.commentCard(maria: maria)]),
            Message(id: "m1", conversationID: "maria", sender: maria, text: "Do you have a moment to look at the new layout?", createdAt: now.addingTimeInterval(-1800)),
            Message(id: "m2", conversationID: "maria", sender: Self.me, text: "Absolutely. Send it over!", createdAt: now.addingTimeInterval(-1700)),
            Message(id: "m3", conversationID: "maria", sender: maria, text: "", createdAt: now.addingTimeInterval(-1650),
                    attachments: [Self.demoVoice]),
            Message(id: "a1", conversationID: "alex", sender: alex, text: "The build is ready for a first look 👋", createdAt: now.addingTimeInterval(-600)),
            Message(id: "g1", conversationID: "general", sender: alex, text: "@Dave could you share the release notes before Friday?", createdAt: now.addingTimeInterval(-5400),
                    replyCount: 1, formatting: [TextStyleRange(style: .mention(userID: Self.me.id), start: 0, length: 5)]),
            Message(id: "g1r", conversationID: "general", threadID: "g1", sender: maria, text: "I can draft the summary part.", createdAt: now.addingTimeInterval(-450)),
            Message(id: "l1", conversationID: "launch", sender: alex, text: "Launch plan for next week", createdAt: now.addingTimeInterval(-7_400),
                    attachments: [Attachment(name: "Launch plan", contentType: "application/vnd.google-apps.document", kind: .link,
                                             url: URL(string: "https://docs.google.com/document/d/demo/edit"))]),
            Message(id: "l2", conversationID: "launch", sender: maria, text: "", createdAt: now.addingTimeInterval(-7_200),
                    attachments: [Attachment(name: "Launch banner.png", contentType: "image/png", kind: .image,
                                             thumbnailURL: URL(string: "https://parley.example/launch-banner.png"), width: 640, height: 360)])
        ]
        let lines = ["ok", "Deploying the new build now, will report back in a few minutes.", "https://example.com/pull/42",
                     "Can you take a look at the failing check? It only fails on the second run, which makes me think the cache is involved somewhere.",
                     "👍", "Merged.\nRolling out to staging first, then everywhere after lunch if nothing looks off."]
        if formattedThread {
            let assistant = Person(id: "assistant", name: "Assistant")
            rooms.append(Conversation(id: "assistant", name: "Assistant", kind: .direct, members: [Self.me, assistant]))
            var text = "Here are some things I can help with:\n", formatting: [TextStyleRange] = []
            let items = ["Answer questions", "Summarize threads", "Draft replies", "Plan projects", "Brainstorm ideas", "Explain code",
                         "Translate text", "Proofread writing", "Compare options", "Outline documents", "Write emails", "Find patterns",
                         "Suggest names", "Create checklists", "Break down tasks", "Review plans", "Prepare meetings"]
            for (index, item) in items.enumerated() {
                let start = text.utf16.count
                let line = "\(item): a short explanation of what that means in practice" + (index < items.count - 1 ? "\n" : "")
                text += line
                formatting += [TextStyleRange(style: .listItem, start: start, length: line.utf16.count),
                               TextStyleRange(style: .bold, start: start, length: item.utf16.count)]
            }
            history += [
                Message(id: "q1", conversationID: "assistant", sender: Self.me, text: "What can you do?", createdAt: now.addingTimeInterval(-120), replyCount: 1),
                Message(id: "q1r", conversationID: "assistant", threadID: "q1", sender: assistant, text: text, createdAt: now.addingTimeInterval(-110),
                        formatting: formatting)
            ]
        }
        history += (0..<longHistory).map { i in
            Message(id: "e\(i)", conversationID: "engineering", sender: i % 3 == 0 ? Self.me : alex,
                    text: "\(i) · \(lines[i % lines.count])", createdAt: now.addingTimeInterval(Double(i - longHistory) * 1_800))
        }
    }
    func connect() throws -> Person {
        if signedOut { signedOut = false; throw AuthFailure.signInRequired }
        if cancelNextConnect { cancelNextConnect = false; throw CancellationError() }
        continuation.yield(.ownStatusChanged(ownStatus))
        continuation.yield(.connectionChanged(.connected)); return Self.me
    }
    func simulateSignedOut() { signedOut = true }
    private var expireOnNextSend: AuthFailure?
    /// Google stops accepting the session mid-use, without the backend reporting it as an event first.
    func simulateSessionExpiredOnNextSend(_ failure: AuthFailure = .signInRequired) { expireOnNextSend = failure }
    private var cancelNextConnect = false
    /// A start that was superseded or whose view went away, as the window closing mid-connect does.
    func simulateCancelledConnect() { cancelNextConnect = true }
    /// Each with its newest message's time as its activity, as the server's sort time.
    func conversations() -> [Conversation] {
        rooms.map { room in
            var room = room
            room.activity = room.activity ?? history.filter { $0.conversationID == room.id }.map(\.createdAt).max()
            return room
        }
    }
    func members(of conversation: ConversationID) -> [Person] {
        memberRequests.append(conversation)
        return rooms.first { $0.id == conversation }?.members ?? []
    }
    private var refusedHistory: Set<ConversationID> = []
    /// Google refusing a conversation's history (HTTP 403).
    func simulateRefusedHistory(_ conversation: ConversationID) { refusedHistory.insert(conversation) }
    func messages(in conversation: ConversationID, thread: ThreadID?, before: Date?) async throws -> MessagePage {
        historyRequests += 1
        if refusedHistory.contains(conversation) { throw AuthFailure.http(403) }
        if latency > .zero { try? await Task.sleep(for: latency) }
        let filtered = history.filter { $0.conversationID == conversation && $0.threadID == thread && (before == nil || $0.createdAt < before!) }.sorted { $0.createdAt < $1.createdAt }
        return MessagePage(messages: Array(filtered.suffix(50)), hasMore: filtered.count > 50)
    }
    private var newestShown: [ConversationID: Date] = [:]
    private func mainTimeline(_ conversation: ConversationID) -> [Message] {
        history.filter { $0.conversationID == conversation && $0.threadID == nil }.sorted { $0.createdAt < $1.createdAt }
    }
    /// 15 messages each side of `message`, as a window around it.
    func messages(around message: MessageID, in conversation: ConversationID) -> MessagePage {
        historyRequests += 1
        let all = mainTimeline(conversation)
        guard let at = all.firstIndex(where: { $0.id == message }) else { return MessagePage(messages: Array(all.suffix(50)), hasMore: all.count > 50) }
        let low = max(0, at - 15), high = min(all.count, at + 16)
        newestShown[conversation] = all[high - 1].createdAt
        return MessagePage(messages: Array(all[low..<high]), hasMore: low > 0, hasNewer: high < all.count)
    }
    func newerMessages(in conversation: ConversationID) -> MessagePage {
        historyRequests += 1
        guard let after = newestShown[conversation] else { return MessagePage(messages: [], hasMore: true) }
        let newer = mainTimeline(conversation).filter { $0.createdAt > after }
        let page = Array(newer.prefix(50))
        newestShown[conversation] = page.last?.createdAt ?? after
        return MessagePage(messages: page, hasMore: true, hasNewer: newer.count > 50)
    }
    func threads(in conversation: ConversationID) -> [ThreadSummary] {
        mainTimeline(conversation).filter { $0.replyCount > 0 }.map { head in
            let replies = history.filter { $0.threadID == head.id }
            return ThreadSummary(head: head, replyCount: head.replyCount, unreadCount: 0, mentionsMe: false, following: head.following,
                                 lastReply: replies.map(\.createdAt).max() ?? head.createdAt)
        }.sorted { $0.lastReply > $1.lastReply }
    }
    /// Someone else's message, pushed as Google Chat pushes one.
    func simulateIncoming(_ message: Message) {
        history.append(message)
        continuation.yield(.messageUpserted(message))
    }
    func send(_ draft: MessageDraft, to conversation: ConversationID, thread: ThreadID?) throws -> Message {
        sentDrafts.append(draft)
        if failNextSend { failNextSend = false; throw CocoaError(.fileWriteUnknown) }
        if let expiry = expireOnNextSend { expireOnNextSend = nil; throw expiry }
        if let id = draft.serverDraftID {   // the server drops the draft or scheduled message it names
            serverDrafts.removeAll { $0.id == id }; scheduledMessages.removeAll { $0.id == id }
        }
        let message = Message(id: UUID().uuidString, conversationID: conversation, threadID: thread, sender: Self.me, text: draft.text,
                              attachments: draft.uploads, formatting: draft.formatting,
                              quote: draft.quoting.map { QuotedMessage(sender: $0.sender, text: $0.text) })
        history.append(message)
        continuation.yield(.messageUpserted(message))
        if let thread, let index = history.firstIndex(where: { $0.id == thread }) {
            history[index].replyCount += 1
            continuation.yield(.messageUpserted(history[index]))
        }
        return message
    }
    func sendMeetLink(in conversation: ConversationID) throws -> Message {
        let meeting = Attachment(name: "Join video meeting", kind: .call, url: URL(string: "https://meet.google.com/abc-defg-hij"), call: .join)
        return try send(MessageDraft(text: "", localID: UUID().uuidString, uploads: [meeting]), to: conversation, thread: nil)
    }
    func edit(_ id: MessageID, text: String, formatting: [TextStyleRange] = []) {
        guard let i = history.firstIndex(where: { $0.id == id && $0.sender.id == Self.me.id }) else { return }
        history[i].text = text; history[i].formatting = formatting; history[i].edited = true
        continuation.yield(.messageUpserted(history[i]))
    }
    func delete(_ id: MessageID) {
        history.removeAll { $0.id == id && $0.sender.id == Self.me.id }
        continuation.yield(.messageDeleted(id))
    }
    /// A workspace's own emoji; its picture is `attachmentData`'s generated gradient.
    static let shipIt = CustomEmoji(id: "demo-ship-it", shortcode: "ship-it", imageURL: URL(string: "https://example.invalid/emoji/ship-it"))
    static let customEmoji = [shipIt, CustomEmoji(id: "demo-lgtm", shortcode: "lgtm", imageURL: URL(string: "https://example.invalid/emoji/lgtm")),
                              CustomEmoji(id: "demo-party-parrot", shortcode: "party-parrot", imageURL: URL(string: "https://example.invalid/emoji/party-parrot"))]
    func customEmojis() -> [CustomEmoji] { Self.customEmoji }
    /// The demo apps' commands, matched as the server does: the query anywhere in the name.
    static let slashCommands = [
        SlashCommand(appID: shipyard.id, appName: shipyard.name, appAvatar: shipyardIcon, name: "/deploy", id: 1, description: "Deploy a build", opensDialog: true),
        SlashCommand(appID: shipyard.id, appName: shipyard.name, appAvatar: shipyardIcon, name: "/shipyard_help", id: 2, description: "Show what Shipyard can do"),
        SlashCommand(appID: notebook.id, appName: notebook.name, appAvatar: notebookIcon, name: "/notebook_help", id: 1, description: "Show the help card"),
    ]
    /// Google Chat's own "Send a Meet link", listed first as the server lists it.
    static let meetLink = SlashCommand(appID: "", appName: "Google Meet", name: "", id: 0, description: "Send a new meeting link",
                                       action: .meetLink, title: "Send a Meet link")
    /// Shipyard's quick command: its "Create issue" dialog, with no message.
    static let createIssueCommand = SlashCommand(appID: shipyard.id, appName: shipyard.name, appAvatar: shipyardIcon, name: "", id: 3,
                                                 description: "Open an issue", opensDialog: true, action: .quick, title: "Create issue")
    private(set) var slashCommandRequests: [(query: String, toApp: Bool)] = []
    /// A space's apps' commands; a person's DM has no apps, so only Google Chat's Meet link.
    func slashCommands(in conversation: ConversationID, matching query: String, toApp: Bool) -> [SlashCommand] {
        slashCommandRequests.append((query, toApp))
        let space = rooms.first { $0.id == conversation }?.kind == .space
        let commands = space ? Self.slashCommands + [Self.createIssueCommand] : []
        return ([Self.meetLink] + commands).filter { query.isEmpty || $0.label.lowercased().contains(query.lowercased()) }
    }
    func setReaction(_ emoji: String, custom: CustomEmoji?, on id: MessageID, present: Bool) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        var reactions = history[i].reactions
        if let r = reactions.firstIndex(where: { $0.emoji == emoji }) {
            if present { reactions[r].people.insert(Self.me.id) } else { reactions[r].people.remove(Self.me.id) }
        } else if present { reactions.append(Reaction(emoji: emoji, people: [Self.me.id], custom: custom)) }
        history[i].reactions = reactions.filter { !$0.people.isEmpty }
        continuation.yield(.messageUpserted(history[i]))
    }
    private(set) var reactorRequests = 0
    func reactors(of id: MessageID, emoji: String, custom: CustomEmoji?) -> [Person] {
        reactorRequests += 1
        let everyone = Dictionary((rooms.flatMap(\.members) + [Self.me]).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = history.first { $0.id == id }?.reactions.first { $0.emoji == emoji }?.people ?? []
        return ids.sorted().map { everyone[$0] ?? Person(id: $0, name: "Unknown") }
    }
    private var failNextRead = false
    func simulateReadFailure() { failNextRead = true }
    func markRead(_ conversation: ConversationID) throws {
        if failNextRead { failNextRead = false; throw AuthFailure.http(400) }
        markedRead.append(conversation)
        if let i = rooms.firstIndex(where: { $0.id == conversation }) { rooms[i].unread = 0 }
        continuation.yield(.readStateChanged(conversation, unread: 0))
    }
    // Sidebar actions: applied to `rooms`, so a refresh shows them as the server would.
    private(set) var changes: [String] = []   // "pin <id>", "unpin <id>", "mute <id>", "unmute <id>", "unread <id>", "leave <id>", "level <level>[ muted] <id>",
                                              // "rename <name> <id>", "emoji <emoji> <id>", "add <ids> <id>", "remove <person> <id>", "hide <id>"
    private var failNextChange = false
    func simulateChangeFailure() { failNextChange = true }
    private func change(_ name: String, _ id: ConversationID, _ edit: (inout Conversation) -> Void) async throws {
        changes.append("\(name) \(id)")
        if latency > .zero { try? await Task.sleep(for: latency) }
        if failNextChange { failNextChange = false; throw URLError(.networkConnectionLost) }
        if let i = rooms.firstIndex(where: { $0.id == id }) { edit(&rooms[i]) }
    }
    private(set) var threadsRead: [ThreadID] = []
    func markThreadRead(_ thread: ThreadID, upTo time: Date) { threadsRead.append(thread) }
    /// As the server does it: the THREAD_FOLLOWED label event follows the change.
    func setFollowing(_ following: Bool, thread: ThreadID) async throws {
        changes.append("\(following ? "follow" : "unfollow") \(thread)")
        if latency > .zero { try? await Task.sleep(for: latency) }
        if failNextChange { failNextChange = false; throw URLError(.networkConnectionLost) }
        continuation.yield(.threadFollowChanged(thread, following: following))
    }
    func setPinned(_ pinned: Bool, conversation: ConversationID) async throws { try await change(pinned ? "pin" : "unpin", conversation) { $0.pinned = pinned } }
    func setMuted(_ muted: Bool, conversation: ConversationID) async throws { try await change(muted ? "mute" : "unmute", conversation) { $0.muted = muted } }
    func setNotificationLevel(_ level: NotificationLevel, muted: Bool, conversation: ConversationID) async throws {
        try await change("level \(level.rawValue)\(muted ? " muted" : "")", conversation) { $0.notificationLevel = level }
    }
    func markUnread(_ conversation: ConversationID) async throws { try await change("unread", conversation) { $0.unread = max($0.unread, 1) } }
    func markUnread(from message: Message) async throws { try await change("unread from \(message.id)", message.conversationID) { $0.unread = max($0.unread, 1) } }
    func leave(_ conversation: ConversationID) async throws {
        try await change("leave", conversation) { _ in }
        rooms.removeAll { $0.id == conversation }
    }
    /// I manage every space and group but General, where I am a plain member.
    private var typingDisallowed: Set<ConversationID> = []
    func disallowTyping(in conversation: ConversationID) { typingDisallowed.insert(conversation) }
    func permissions(in conversation: ConversationID) -> ConversationPermissions {
        let typing = !typingDisallowed.contains(conversation)
        guard let room = rooms.first(where: { $0.id == conversation }), room.kind != .direct, room.id != "general" else { return .init(typing: typing) }
        return ConversationPermissions(editProfile: true, manageMembers: true, typing: typing, editDetails: true, deleteSpace: true,
                                       changeRoles: true, changeManagers: true, toggleHistory: true)
    }
    private var memberRoles: [ConversationID: [PersonID: MemberRole]] = [:]
    private var sections: [SidebarSection] = []
    func sidebarSections() -> [SidebarSection] { sections }
    func createSection(named name: String, at position: Int) async throws -> SidebarSection {
        let made = SidebarSection(kind: .custom, key: "k\(sections.count + 1)", name: name, position: position)
        sections.append(made)
        changes.append("section \(name)")
        return made
    }
    func renameSection(_ section: SidebarSection, to name: String) async throws {
        if let i = sections.firstIndex(of: section) { sections[i].name = name }
    }
    func moveSection(_ section: SidebarSection, to position: Int) async throws {
        if let i = sections.firstIndex(of: section) { sections[i].position = position }
    }
    func deleteSection(_ section: SidebarSection) async throws {
        sections.removeAll { $0.key == section.key }
        for i in rooms.indices where rooms[i].section == section.key { rooms[i].section = nil }
    }
    func moveConversation(_ conversation: ConversationID, to section: String?, from previous: String?) async throws {
        try await change("move to \(section ?? "default")", conversation) { $0.section = section }
    }
    private var blocked: Set<PersonID> = []
    func setBlocked(_ blocked: Bool, person: PersonID, dm: ConversationID?, report: Bool) async throws {
        changes.append("\(blocked ? "block" : "unblock") \(person)")
        if blocked { self.blocked.insert(person) } else { self.blocked.remove(person) }
    }
    func setBlocked(_ blocked: Bool, space: ConversationID, report: Bool) async throws {
        try await change(blocked ? "block" : "unblock", space) { _ in }
    }
    func blockedPeople() -> [PersonID] { blocked.sorted() }
    func blockedSpaces() -> [BlockedSpace] { [] }
    private(set) var reports: [(MessageID, ReportReason)] = []
    func report(_ message: Message, reason: ReportReason, explanation: String) async throws { reports.append((message.id, reason)) }
    func createSpace(name: String, emoji: String?) async throws -> Conversation {
        let room = Conversation(id: "space/" + UUID().uuidString, name: name, kind: .space, members: [Self.me], emoji: emoji)
        rooms.insert(room, at: 0)
        return room
    }
    func deleteSpace(_ conversation: ConversationID) async throws {
        try await change("delete", conversation) { _ in }
        rooms.removeAll { $0.id == conversation }
    }
    func updateDetails(_ conversation: ConversationID, description: String, guidelines: String) async throws {
        try await change("details", conversation) { $0.description = description; $0.guidelines = guidelines }
    }
    func setRole(_ role: MemberRole, of person: PersonID, in conversation: ConversationID) async throws {
        try await change("role \(role.rawValue) \(person)", conversation) { _ in }
        memberRoles[conversation, default: [:]][person] = role
    }
    func setHistory(_ on: Bool, in conversation: ConversationID) async throws {
        try await change(on ? "history on" : "history off", conversation) { $0.historyOff = !on }
    }
    func roles(in conversation: ConversationID) -> [PersonID: MemberRole] { memberRoles[conversation] ?? [:] }
    func updateProfile(_ conversation: ConversationID, name: String?, emoji: String?) async throws {
        if let name { try await change("rename \(name)", conversation) { $0.name = name } }
        if let emoji { try await change("emoji \(emoji)", conversation) { $0.emoji = emoji } }
    }
    func addMembers(_ people: [PersonID], to conversation: ConversationID) async throws {
        let everyone = Dictionary((rooms.flatMap(\.members) + directory).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        try await change("add \(people.joined(separator: ","))", conversation) { room in
            room.members += people.filter { id in !room.members.contains { $0.id == id } }.map { everyone[$0] ?? Person(id: $0, name: $0) }
        }
    }
    func removeMember(_ person: PersonID, from conversation: ConversationID) async throws {
        try await change("remove \(person)", conversation) { $0.members.removeAll { $0.id == person } }
    }
    func setHidden(_ hidden: Bool, conversation: ConversationID) async throws {
        try await change(hidden ? "hide" : "unhide", conversation) { $0.hidden = hidden ? .now : nil }
    }
    // ponytail: From, dates and images only; the other chips match everything here.
    func searchMessages(_ query: String, filters: SearchFilters, cursor: String?) -> SearchPage {
        SearchPage(messages: history.filter { message in
            (query.isEmpty || message.text.localizedCaseInsensitiveContains(query))
                && (filters.from.isEmpty || filters.from.contains { $0.id == message.sender.id })
                && (filters.saidIn.isEmpty || filters.saidIn.contains(message.conversationID))
                && filters.after.map { message.createdAt >= $0 } ?? true && filters.before.map { message.createdAt < $0 } ?? true
                && (!filters.has.contains(.image) || message.attachments.contains { $0.kind == .image })
        })
    }
    private(set) var typingSent: [String] = []   // "<conversation>/<thread or timeline>"
    private(set) var watched: [Set<ConversationID>] = []
    private(set) var presenceRequests: [[String]] = []
    private var typingRefused: Set<String> = []
    func refuseTyping(in scope: String) { typingRefused.insert(scope) }
    func sendTyping(conversation: ConversationID, thread: ThreadID?) throws {
        let scope = "\(conversation)/\(thread ?? "timeline")"
        typingSent.append(scope)
        if typingRefused.contains(scope) { throw AuthFailure.http(403) }
    }
    func watch(_ conversations: Set<ConversationID>) { watched.append(conversations) }
    /// Everyone a presence lookup answered with a state, so a test can wait until the store has applied them all.
    private(set) var presenceAnswered: Set<String> = []
    func fetchPresence(_ people: [String]) {
        presenceRequests.append(people)
        let everyone = Dictionary(rooms.flatMap(\.members).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in people { if let person = everyone[id] {
            if person.presence != nil { presenceAnswered.insert(id) }
            continuation.yield(.presenceChanged(id, person.presence, status: nil))
        } }
    }
    /// Mine, kept as the server would: automatic, away and DND exclude each other.
    private(set) var ownStatus = OwnStatus()
    func setDoNotDisturb(for duration: TimeInterval) -> OwnStatus {
        ownStatus.availability = .doNotDisturb(until: .now.addingTimeInterval(duration)); return ownStatus
    }
    func setAway(_ away: Bool) -> OwnStatus { ownStatus.availability = away ? .away : .automatic; return ownStatus }
    func setCustomStatus(_ status: CustomStatus?) -> OwnStatus { ownStatus.custom = status; return ownStatus }
    // New conversations: people outside the sidebar and spaces not yet joined.
    private let directory = [Person(id: "priya", name: "Priya Patel", presence: .available, email: "priya@example.com"),
                             Person(id: "sam", name: "Sam Okafor", presence: .away, email: "sam@example.com")]
    private var listings = [SpaceListing(id: "photography", name: "Photography", emoji: "📷", memberCount: 48),
                            SpaceListing(id: "book-club", name: "Book club", emoji: "📚", memberCount: 9)]
    private(set) var directMessageRequests: [[PersonID]] = []
    private(set) var joined: [ConversationID] = []
    private var failDirectory = false
    func simulateDirectoryFailure() { failDirectory = true }
    func searchPeople(_ query: String) -> [Person] {
        let everyone = Dictionary((rooms.flatMap(\.members) + directory).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values
        let q = query.trimmingCharacters(in: .whitespaces)
        return everyone.filter { $0.id != Self.me.id && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.email?.localizedCaseInsensitiveContains(q) == true) }
            .sorted { $0.name < $1.name }
    }
    func directMessage(with ids: [PersonID]) -> Conversation {
        directMessageRequests.append(ids)
        let others = Set(ids).subtracting([Self.me.id])
        if let room = rooms.first(where: { $0.kind != .space && Set($0.members.map(\.id)).subtracting([Self.me.id]) == others }) { return room }
        let everyone = Dictionary((rooms.flatMap(\.members) + directory).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let members = ids.map { everyone[$0] ?? Person.invitedEmail($0).map(Person.invite(email:)) ?? Person(id: $0, name: $0) }
        let room = Conversation(id: "dm-" + ids.joined(separator: "-"), name: members.map(\.name).sorted().joined(separator: ", "),
                                kind: members.count == 1 ? .direct : .group, members: [Self.me] + members)
        rooms.insert(room, at: 0)
        return room
    }
    func invite(_ listing: SpaceListing) { listings.insert(listing, at: 0) }
    func browseSpaces(_ query: String) throws -> [SpaceListing] {
        if failDirectory { failDirectory = false; throw URLError(.notConnectedToInternet) }
        return listings.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { listing in var listing = listing; listing.joined = rooms.contains { $0.id == listing.id }; return listing }
    }
    /// What the history shares, as the server would list it (one page).
    func shared(_ category: SharedCategory, in conversation: ConversationID, after: SharedContent.Item?) -> SharedPage {
        let content = SharedContent(history.filter { $0.conversationID == conversation })
        let items = switch category { case .media: content.media; case .files: content.files; case .links: content.links }
        return SharedPage(items: after == nil ? items : [], hasMore: false)
    }
    func join(_ space: SpaceListing) -> Conversation {
        joined.append(space.id)
        let room = Conversation(id: space.id, name: space.name, kind: .space, members: [Self.me], emoji: space.emoji)
        rooms.insert(room, at: 0)
        return room
    }
    func setStarred(_ starred: Bool, on id: MessageID) async throws {
        changes.append("\(starred ? "star" : "unstar") \(id)")
        if latency > .zero { try? await Task.sleep(for: latency) }
        if failNextChange { failNextChange = false; throw URLError(.networkConnectionLost) }
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].starred = starred
        continuation.yield(.messageUpserted(history[i]))
    }
    func setPinned(_ pinned: Bool, on id: MessageID) async throws {
        changes.append("\(pinned ? "pin" : "unpin") \(id)")
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].pinned = pinned
        continuation.yield(.messageUpserted(history[i]))
    }
    /// The demo's schedule: weeknights, switched off.
    private var schedules = DndSchedules(periods: [.init(days: [7, 1, 2, 3, 4], start: 22 * 60, end: 7 * 60, enabled: false)])
    func dndSchedules(timeZone: String) -> DndSchedules { schedules }
    func setDndSchedules(_ schedules: DndSchedules) throws {
        if failNextChange { failNextChange = false; throw URLError(.networkConnectionLost) }
        self.schedules = schedules
    }
    /// A pin made elsewhere: Google keeps it, and nothing is pushed.
    func simulatePinned(_ id: MessageID) { if let i = history.firstIndex(where: { $0.id == id }) { history[i].pinned = true } }
    func pinnedMessages(in conversation: ConversationID) -> [Message] { history.filter { $0.conversationID == conversation && $0.pinned } }
    /// The server's followed threads as tests set them; nil derives them from the history.
    private var serverHome: [HomeThread]?
    func setHomeThreads(_ threads: [HomeThread]) { serverHome = threads }
    /// Home's thread rows: every thread with a reply, the General one unread.
    func homeThreads() -> [HomeThread] {
        if let serverHome { return serverHome }
        return history.filter { $0.replyCount > 0 && $0.threadID == nil }.compactMap { head in
            guard let latest = history.filter({ $0.threadID == head.id }).max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            return HomeThread(id: head.id, conversationID: head.conversationID, head: head, latest: latest, unread: head.id == "g1", time: latest.createdAt)
        }.sorted { $0.time > $1.time }
    }
    /// Every starred message, or every one that names me, newest first, in one page.
    func shortcut(_ shortcut: Shortcut, cursor: String?) -> SearchPage {
        let found = history.filter { shortcut == .starred ? $0.starred : NotificationPolicy.mentions($0, me: Self.me.id) }
        return SearchPage(messages: cursor == nil ? found.sorted { $0.createdAt > $1.createdAt } : [])
    }
    /// Server drafts, as Google keeps them; the demo has one waiting in Launch crew.
    private(set) var serverDrafts = [ServerDraft(id: "demo-draft", conversationID: "launch", text: "Notes for Friday: beta first, then ",
                                                 updatedAt: .now.addingTimeInterval(-1_200))]
    private(set) var draftWrites: [String] = []   // "create|update|delete <conversation>/<thread or timeline>"
    private var failDraftWrites = false
    func simulateDraftFailure(_ fail: Bool = true) { failDraftWrites = fail }
    /// Draft saves that take this long, so a send can happen while one is on its way.
    func simulateSlowDraftWrites(_ latency: Duration) { draftLatency = latency }
    private var draftLatency: Duration = .zero
    func simulateDrafts(_ drafts: [ServerDraft]) { serverDrafts = drafts }
    func drafts() -> [ServerDraft] { serverDrafts }
    func saveDraft(_ draft: ServerDraft) async throws -> ServerDraft {
        if draft.schedule != nil {   // a scheduled message
            var saved = draft
            saved.id = UUID().uuidString; saved.updatedAt = .now
            scheduledMessages.append(saved)
            return saved
        }
        draftWrites.append("\(draft.id.isEmpty ? "create" : "update") \(draft.conversationID)/\(draft.threadID ?? "timeline")")
        if failDraftWrites { throw URLError(.networkConnectionLost) }
        if draftLatency > .zero { try? await Task.sleep(for: draftLatency) }
        var saved = draft
        if saved.id.isEmpty { saved.id = UUID().uuidString }
        saved.updatedAt = .now
        serverDrafts.removeAll { $0.id == saved.id }
        serverDrafts.append(saved)
        return saved
    }
    func deleteDraft(_ draft: ServerDraft) throws {
        if draft.schedule != nil { scheduledMessages.removeAll { $0.id == draft.id }; return }
        draftWrites.append("delete \(draft.conversationID)/\(draft.threadID ?? "timeline")")
        if failDraftWrites { throw URLError(.networkConnectionLost) }
        serverDrafts.removeAll { $0.id == draft.id }
    }
    /// Scheduled messages, as Google keeps them; the demo has one going to Launch crew tomorrow morning.
    private(set) var scheduledMessages = [ServerDraft(id: "demo-scheduled", conversationID: "launch", text: "Reminder: the beta build goes out at noon",
                                                      schedule: .init(at: Calendar.current.date(byAdding: .day, value: 1,
                                                                                                to: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!)!))]
    func simulateScheduled(_ messages: [ServerDraft]) { scheduledMessages = messages }
    func scheduled() -> [ServerDraft] { scheduledMessages }
    func reschedule(_ message: ServerDraft, to date: Date) -> ServerDraft {
        var moved = message
        moved.schedule = .init(at: date)
        if let index = scheduledMessages.firstIndex(where: { $0.id == message.id }) { scheduledMessages[index] = moved }
        return moved
    }
    /// Pushes an event as the server would, for tests and previews.
    func push(_ event: ChatEvent) { continuation.yield(event) }
    func simulateSendFailure() { failNextSend = true }
    private(set) var cardClicks: [String] = []   // "<message id> card=<id> <input>=<value> …"
    private var cardRefusal: String?
    /// The next card action is refused, as an app (or the server for it) refuses one, saying why.
    func refuseNextCardClick(_ why: String) { cardRefusal = why }
    /// A card action: the app answers by updating the message, as a documents app does when a reply is posted: the reply
    /// joins the comment, or the comment is resolved.
    func clickCard(_ id: MessageID, card: String?, action: Data, inputs: [Card.Input]) async throws -> Message? {
        cardClicks.append(([id] + (card.map { ["card=\($0)"] } ?? []) + inputs.map { "\($0.name)=\($0.value)" }).joined(separator: " "))
        if failNextChange { failNextChange = false; throw URLError(.networkConnectionLost) }
        if let why = cardRefusal { cardRefusal = nil; throw DynamiteError.appRefused(why) }
        guard let i = history.firstIndex(where: { $0.id == id }) else { return nil }
        history[i].edited = true
        if var card = history[i].attachments.first?.card, let input = card.sections.firstIndex(where: { $0.contains { if case .field = $0 { true } else { false } } }) {
            let function = (try? Dynamite_CardAction(serializedBytes: action))?.function
            if function == "RESOLVE_COMMENT" {
                card.sections.replaceSubrange(input..., with: [[.text("Dave resolved this comment", [TextStyleRange(style: .italic, start: 0, length: 26)])]])
            } else if let reply = inputs.first?.value, !reply.isEmpty {
                card.sections.insert([.row(icon: nil, round: true, label: Self.me.name, text: reply, formatting: [])], at: input)
            }
            history[i].attachments[0].card = card
        }
        return history[i]
    }
    private(set) var dialogSteps: [String] = []   // "<step> <message id> app=<id> <input>=<value> …"
    private var dialogAnswer: DialogAnswer?
    /// The next dialog request gets this answer, as an app answers one (another step, a refusal).
    func answerNextDialog(_ answer: DialogAnswer) { dialogAnswer = answer }
    /// The code-review app's "Create issue" dialog: a title it requires and a priority. Created, the issue arrives as a
    /// message from the app and the dialog closes with its note.
    func dialog(_ step: DialogStep, _ context: DialogContext, action: Data?, inputs: [Card.Input]) async throws -> DialogAnswer {
        dialogSteps.append((["\(step)", context.message, "app=\(context.app)"] + inputs.map { "\($0.name)=\($0.value)" }).joined(separator: " "))
        if failNextChange { failNextChange = false; throw URLError(.networkConnectionLost) }
        if let answer = dialogAnswer { dialogAnswer = nil; return answer }
        switch step {
        case .open: return .show(Self.createIssue)
        case .cancel: return .close(nil)
        case .submit where (try? Dynamite_CardAction(serializedBytes: action ?? Data()))?.function == "cancel": return .close(nil)
        case .submit:
            let title = inputs.first { $0.name == "title" }?.value.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { return .invalid("Give the issue a title.") }
            let conversation = context.command != nil ? context.message : history.first { $0.id == context.message }?.conversationID ?? "design"
            let issue = Message(id: "issue\(history.count)", conversationID: conversation, sender: Self.shipyard,
                                text: "Issue #43 opened: \(title)", createdAt: .now)
            history.append(issue)
            push(.messageUpserted(issue))
            return .close("Issue #43 created.")
        }
    }
    static let shipyard = Person(id: "shipyard", name: "Shipyard", avatarURL: shipyardIcon)
    /// Shipyard's dialog: a title, a priority menu, Cancel and Create.
    static let createIssue: AppDialog = {
        func action(_ function: String) -> Data { (try? Dynamite_CardAction.with { $0.function = function }.serializedData()) ?? Data() }
        let page = URL(string: "https://shipyard.example/issues/new")!
        return AppDialog(title: "Create issue", card: Card(sections: [[
            .field(Card.Field(name: "title", label: "Title", value: "", placeholder: "What needs doing?", required: true)),
            .field(Card.Field(name: "details", label: "Details", value: "", multiline: true)),
            .choice(Card.Choice(name: "priority", label: "Priority", style: .menu, options: [
                .init(text: "Low", value: "low", selected: false), .init(text: "Normal", value: "normal", selected: true),
                .init(text: "High", value: "high", selected: false)])),
        ]]), primary: Card.Link(title: "Create", url: page, filled: true, action: action("create"), required: ["title"]),
             secondary: Card.Link(title: "Cancel", url: page, action: action("cancel")))
    }()
    // Demo apps. Their icons are drawn locally (`demoIcons`), as nothing is fetched in the demo.
    static let shipyardIcon = URL(string: "https://shipyard.example/icon.png")!
    static let notebookIcon = URL(string: "https://notebook.example/icon.png")!
    static let documentIcon = URL(string: "https://notebook.example/document.png")!
    static let notebook = Person(id: "notebook", name: "Notebook", avatarURL: notebookIcon)
    /// The pictures behind the demo's icon URLs: a symbol on a coloured tile.
    @MainActor static var demoIcons: [(URL, NSImage)] {
        func tile(_ symbol: String, _ colour: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                colour.setFill(); NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
                let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 34, weight: .semibold).applying(.init(paletteColors: [.white])))
                glyph?.draw(in: rect.insetBy(dx: 14, dy: 14)); return true
            }
        }
        return [(shipyardIcon, tile("shippingbox.fill", .systemIndigo)), (notebookIcon, tile("book.closed.fill", .systemOrange)),
                (documentIcon, tile("doc.text.fill", .systemBlue))]
    }
    /// A code-review app's preview of a link, as Google Chat sends one: a one-line linked title over a small grey line
    /// (its state in green), a description cut to two lines, and the app that made it.
    static let shipyardPreview: Attachment = {
        let link = URL(string: "https://shipyard.example/pr/42")!
        let title = "#42 Compact sidebar and native text", label = "Open · design/parley · Author: alex"
        let start = title.utf16.count + 1
        let body = "Tightens the sidebar to native row heights, draws message text with the system text view so selection, links and "
            + "spelling behave like any Mac app, and keeps threads in a side pane that never covers the conversation."
        var card = Card(sections: [[
            .row(icon: nil, round: false, label: nil, text: title + "\n" + label, formatting: [
                TextStyleRange(style: .link(link), start: 0, length: title.utf16.count), TextStyleRange(style: .nowrap, start: 0, length: title.utf16.count),
                TextStyleRange(style: .small, start: start, length: label.utf16.count), TextStyleRange(style: .color(Card.secondaryText), start: start, length: label.utf16.count),
                TextStyleRange(style: .color(0xFF1AA64A), start: start, length: 4)]),
            .text(body, [], lines: 2),
            .links([Card.Link(title: "Create issue", url: link, action: (try? Dynamite_CardAction.with { $0.function = "create_issue"; $0.interaction = 1 }.serializedData()) ?? Data(),
                              dialog: true)]),
        ]])
        card.by = Card.Attribution(name: "Shipyard", icon: shipyardIcon)
        card.app = shipyard.id
        return Attachment(name: title, kind: .card, card: card)
    }()
    /// A documents app's comment notification: the document (the row opens it), the comment, a Reply box, and Reply and
    /// Resolve, which act in the card (`clickCard`), with Open at the end.
    static func commentCard(maria: Person) -> Attachment {
        func action(_ function: String) -> Data { (try? Dynamite_CardAction.with { $0.function = function }.serializedData()) ?? Data() }
        let document = URL(string: "https://notebook.example/d/launch-plan")!
        let comment = "Can we move the beta to Thursday? The release notes need one more pass."
        return Attachment(name: "Launch plan", kind: .card, card: Card(sections: [
            [.row(icon: documentIcon, round: false, label: nil, text: "Launch plan", formatting: [TextStyleRange(style: .nowrap, start: 0, length: 11)], open: document)],
            [.row(icon: nil, round: true, label: maria.name, text: comment, formatting: [])],
            [.field(Card.Field(name: "REPLY_TO_COMMENT", label: "Reply", value: ""))],
            [.links([Card.Link(title: "Reply", url: document, action: action("REPLY_TO_COMMENT")),
                     Card.Link(title: "Resolve", url: document, action: action("RESOLVE_COMMENT")),
                     Card.Link(title: "Open", url: document, trailing: true)])],
        ]))
    }
    func simulateUploadFailure() { failNextUpload = true }
    /// Nothing leaves the Mac: the file stays where it is and the token just names it.
    func upload(_ attachment: Attachment, to conversation: ConversationID, thread: ThreadID?) throws -> Attachment {
        uploaded.append(attachment)
        if failNextUpload { failNextUpload = false; throw URLError(.networkConnectionLost) }
        var done = attachment
        done.uploadToken = "fake-\(attachment.name)"
        return done
    }
    /// A voice message whose audio is a few seconds of humming tone (`attachmentData`).
    static let demoVoice = Attachment(name: "UserRecording_1700000000000.m4a", contentType: Voice.contentType, kind: .voice,
                                      url: URL(string: "https://example.com/demo-voice"),
                                      voice: Voice(duration: 6.4, waveform: (0..<64).map { 20 + Int(60 * abs(sin(Double($0) / 5))) },
                                                   transcript: "Here’s a quick walkthrough of the new layout. Let me know what you think!"))
    /// Uncompressed 16-bit mono PCM in a WAV container.
    static func wav(_ samples: [Int16], rate: Int = 8_000) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let bytes = samples.count * 2
        var data = Data("RIFF".utf8) + le(UInt32(36 + bytes)) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(rate)) + le(UInt32(rate * 2)) + le(UInt16(2)) + le(UInt16(16))
        data += Data("data".utf8) + le(UInt32(bytes))
        samples.forEach { data += le($0) }
        return data
    }
    /// A generated gradient for images and previews; a tone for voice messages; a small text file otherwise.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) throws -> Data {
        if attachment.kind == .voice {
            let rate = 8_000.0, seconds = attachment.voice?.duration ?? 2
            return Self.wav((0..<Int(rate * seconds)).map { i in
                let t = Double(i) / rate
                return Int16(6_000 * abs(sin(t * 2.5)) * sin(2 * .pi * 220 * t))
            })
        }
        guard thumbnail || attachment.kind != .file else { return Data("Parley demo file: \(attachment.name)\n".utf8) }
        let size = NSSize(width: attachment.width ?? 320, height: attachment.height ?? 240)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 45); return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
