import AppKit
import ParleyData
import ParleyDomain

/// Deterministic local demo. No Google requests or credentials.
actor FakeBackend: ChatBackend {
    static let me = Person(id: "me", name: "Dave", presence: .available)
    nonisolated let events: AsyncStream<ChatEvent>
    let continuation: AsyncStream<ChatEvent>.Continuation  // internal for the test hooks, which push events
    private let latency: Duration

    // What the demo server holds; internal where a test hook changes it.
    private var rooms: [Conversation]
    var history: [Message]
    /// Who the next connect signs in as: another account on this Mac.
    var account = me
    private var newestShown: [ConversationID: Date] = [:]
    private var memberRoles: [ConversationID: [PersonID: MemberRole]] = [:]
    private var sections: [SidebarSection] = []
    private var blocked: Set<PersonID> = []
    /// Mine, kept as the server would: automatic, away and DND exclude each other.
    private(set) var ownStatus = OwnStatus()
    // New conversations: people outside the sidebar and spaces not yet joined.
    private let directory = [
        Person(id: "priya", name: "Priya Patel", presence: .available, email: "priya@example.com"),
        Person(id: "sam", name: "Sam Okafor", presence: .away, email: "sam@example.com"),
    ]
    var listings = [
        SpaceListing(id: "photography", name: "Photography", emoji: "📷", memberCount: 48),
        SpaceListing(id: "book-club", name: "Book club", emoji: "📚", memberCount: 9),
    ]
    /// The demo's schedule: weeknights, switched off.
    private var schedules = DndSchedules(periods: [
        .init(days: [7, 1, 2, 3, 4], start: 22 * 60, end: 7 * 60, enabled: false)
    ])
    /// The server's followed threads as tests set them; nil derives them from the history.
    var serverHome: [HomeThread]?
    /// Server drafts, as Google keeps them; the demo has one waiting in Launch crew.
    var serverDrafts = [
        ServerDraft(
            id: "demo-draft", conversationID: "launch", text: "Notes for Friday: beta first, then ",
            updatedAt: .now.addingTimeInterval(-1_200))
    ]
    /// Scheduled messages, as Google keeps them; the demo has one going to Launch crew tomorrow morning.
    var scheduledMessages = [
        ServerDraft(
            id: "demo-scheduled", conversationID: "launch", text: "Reminder: the beta build goes out at noon",
            schedule: .init(
                at: Calendar.current.date(
                    byAdding: .day, value: 1,
                    to: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!)!))
    ]

    // What the test hooks (FakeBackend+TestHooks.swift) make the next request do.
    private var failNextSend = false
    private var failNextUpload = false
    var signedOut = false
    var expireOnNextSend: AuthFailure?
    var cancelNextConnect = false
    var refusedHistory: Set<ConversationID> = []
    var failNextRead = false
    var failNextChange = false
    var typingDisallowed: Set<ConversationID> = []
    var customEmojiAllowed: [ConversationID: Bool] = [:]
    var typingRefused: Set<String> = []
    var failDirectory = false
    var failDraftWrites = false
    var draftLatency: Duration = .zero
    var cardRefusal: String?
    var dialogAnswer: DialogAnswer?

    // What was asked, for tests to check.
    private(set) var sentDrafts: [MessageDraft] = []
    private(set) var uploaded: [Attachment] = []  // every upload attempt
    private(set) var markedRead: [ConversationID] = []
    private(set) var historyRequests = 0
    private(set) var memberRequests: [ConversationID] = []
    private(set) var listReads = 0  // conversation list reads, for tests that count refreshes
    private(set) var slashCommandRequests: [(query: String, toApp: Bool)] = []
    private(set) var reactorRequests = 0
    /// Sidebar and message actions, in order: "pin <id>", "unpin <id>", "mute <id>", "unmute <id>", "unread <id>", "leave <id>",
    /// "level <level>[ muted] <id>", "rename <name> <id>", "emoji <emoji> <id>", "add <ids> <id>", "remove <person> <id>", "hide <id>"…
    private(set) var changes: [String] = []
    private(set) var threadsRead: [ThreadID] = []
    private(set) var reports: [(MessageID, ReportReason)] = []
    private(set) var typingSent: [String] = []  // "<conversation>/<thread or timeline>"
    private(set) var watched: [Set<ConversationID>] = []
    private(set) var presenceRequests: [[PersonID]] = []
    /// Everyone a presence lookup answered with a state, so a test can wait until the store has applied them all.
    private(set) var presenceAnswered: Set<PersonID> = []
    private(set) var directMessageRequests: [[PersonID]] = []
    private(set) var joined: [ConversationID] = []
    private(set) var draftWrites: [String] = []  // "create|update|delete <conversation>/<thread or timeline>"
    private(set) var cardClicks: [String] = []  // "<message id> card=<id> <input>=<value> …"
    private(set) var dialogSteps: [String] = []  // "<step> <message id> app=<id> <input>=<value> …"

    /// `longHistory` adds that many varied messages to Engineering, served in pages after `latency`, for scroll tests.
    /// `manyConversations` adds that many more DMs and spaces (some with long names), for sidebar tests.
    /// `formattedThread` adds a DM whose one thread reply is a long bold-and-list answer, like an assistant's.
    init(longHistory: Int = 0, manyConversations: Int = 0, formattedThread: Bool = false, latency: Duration = .zero) {
        self.latency = latency
        let stream = AsyncStream<ChatEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        (rooms, history) = Self.demoWorkspace(
            longHistory: longHistory, manyConversations: manyConversations, formattedThread: formattedThread)
    }
}

// The demo's answers to what the store asks, as `DynamiteBackend` answers them from Google.
extension FakeBackend {
    /// Everyone in the demo's conversations, then `extra`, by id; the first one listed wins.
    private func peopleByID(adding extra: [Person] = []) -> [PersonID: Person] {
        Dictionary((rooms.flatMap(\.members) + extra).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    func connect() throws -> Person {
        if signedOut {
            signedOut = false
            throw AuthFailure.signInRequired
        }
        if cancelNextConnect {
            cancelNextConnect = false
            throw CancellationError()
        }
        continuation.yield(.ownStatusChanged(ownStatus))
        continuation.yield(.connectionChanged(.connected))
        return account
    }
    /// Each with its newest message's time as its activity, as the server's sort time.
    func conversations() -> [Conversation] {
        listReads += 1
        return rooms.map { room in
            var room = room
            room.activity = room.activity ?? history.filter { $0.conversationID == room.id }.map(\.createdAt).max()
            return room
        }
    }
    func members(of conversation: ConversationID) -> [Person] {
        memberRequests.append(conversation)
        return rooms.first { $0.id == conversation }?.members ?? []
    }
    func messages(in conversation: ConversationID, thread: ThreadID?, before: Date?) async throws -> MessagePage {
        historyRequests += 1
        if refusedHistory.contains(conversation) { throw AuthFailure.http(403) }
        if latency > .zero { try? await Task.sleep(for: latency) }
        let filtered = history.filter {
            $0.conversationID == conversation && $0.threadID == thread && (before == nil || $0.createdAt < before!)
        }.sorted { $0.createdAt < $1.createdAt }
        return MessagePage(messages: Array(filtered.suffix(50)), hasMore: filtered.count > 50)
    }
    private func mainTimeline(_ conversation: ConversationID) -> [Message] {
        history.filter { $0.conversationID == conversation && $0.threadID == nil }.sorted {
            $0.createdAt < $1.createdAt
        }
    }
    /// 15 messages each side of `message`, as a window around it.
    func messages(around message: MessageID, in conversation: ConversationID) -> MessagePage {
        historyRequests += 1
        let all = mainTimeline(conversation)
        guard let at = all.firstIndex(where: { $0.id == message }) else {
            return MessagePage(messages: Array(all.suffix(50)), hasMore: all.count > 50)
        }
        let low = max(0, at - 15)
        let high = min(all.count, at + 16)
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
            let replies = history.filter { $0.threadID == ThreadID(head: head.id) }
            return ThreadSummary(
                head: head, replyCount: head.replyCount, unreadCount: 0, mentionsMe: false, following: head.following,
                lastReply: replies.map(\.createdAt).max() ?? head.createdAt)
        }.sorted { $0.lastReply > $1.lastReply }
    }
    func send(_ draft: MessageDraft, to conversation: ConversationID, thread: ThreadID?) throws -> Message {
        sentDrafts.append(draft)
        if failNextSend {
            failNextSend = false
            throw CocoaError(.fileWriteUnknown)
        }
        if let expiry = expireOnNextSend {
            expireOnNextSend = nil
            throw expiry
        }
        if let id = draft.serverDraftID {  // the server drops the draft or scheduled message it names
            serverDrafts.removeAll { $0.id == id }
            scheduledMessages.removeAll { $0.id == id }
        }
        let message = Message(
            id: MessageID(UUID().uuidString), conversationID: conversation, threadID: thread, sender: Self.me,
            text: draft.text,
            attachments: draft.uploads, formatting: draft.formatting,
            quote: draft.quoting.map { QuotedMessage(sender: $0.sender, text: $0.text) })
        history.append(message)
        continuation.yield(.messageUpserted(message))
        if let thread, let index = history.firstIndex(where: { $0.id == thread.head }) {
            history[index].replyCount += 1
            continuation.yield(.messageUpserted(history[index]))
        }
        return message
    }
    func sendMeetLink(in conversation: ConversationID) throws -> Message {
        let meeting = Attachment(
            name: "Join video meeting", kind: .call, url: URL(string: "https://meet.google.com/abc-defg-hij"),
            call: .join)
        return try send(
            MessageDraft(text: "", localID: UUID().uuidString, uploads: [meeting]), to: conversation, thread: nil)
    }
    func edit(_ id: MessageID, text: String, formatting: [TextStyleRange] = []) {
        guard let index = history.firstIndex(where: { $0.id == id && $0.sender.id == Self.me.id }) else { return }
        history[index].text = text
        history[index].formatting = formatting
        history[index].edited = true
        continuation.yield(.messageUpserted(history[index]))
    }
    func deleteMessage(_ id: MessageID) {
        history.removeAll { $0.id == id && $0.sender.id == Self.me.id }
        continuation.yield(.messageDeleted(id))
    }
    func customEmojis() -> [CustomEmoji] { Self.customEmoji }
    /// The demo's apps in a space or group (Shipyard and Notebook), as autocomplete_bots answers for its own apps.
    func searchApps(in conversation: ConversationID, matching query: String) -> [Person] {
        guard rooms.first(where: { $0.id == conversation })?.kind != .direct else { return [] }
        return [Self.shipyard, Self.notebook].filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
    }
    func searchDriveFiles(matching query: String) -> [DriveFile] {
        query.isEmpty
            ? Array(Self.driveFiles.prefix(2))
            : Self.driveFiles.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    func searchDirectory(matching query: String) -> [Person] {
        query.isEmpty ? [] : MentionQuery.filter([Self.directoryPerson], by: query)
    }
    /// The demo's people work in Lisbon; nobody else shares a calendar zone.
    func timeZone(email: String) -> TimeZone? {
        email.hasSuffix("@example.com") ? TimeZone(identifier: "Europe/Lisbon") : nil
    }
    func jobTitle(email: String, name: String) -> String? { email.hasSuffix("@example.com") ? "Product Designer" : nil }
    /// Everyone in the demo reports to Maria, who has one report; each shares an event, an email and a file with me.
    func personDetails(id: PersonID, email: String?) -> PersonDetails {
        let maria = PersonDetails.Colleague(id: "maria", name: "Maria Chen", title: "Head of Design")
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        return PersonDetails(
            reports: id == "maria" ? [.init(id: "sam", name: "Sam Okafor", title: "Product Designer")] : [],
            reportCount: id == "maria" ? 1 : 0, managers: id == "maria" ? [] : [maria],
            recent: [
                .init(
                    kind: .event, title: "Design review", url: URL(string: "https://example.invalid/event")!, date: day),
                .init(
                    kind: .email, title: "Launch notes", url: URL(string: "https://example.invalid/mail")!, date: day),
            ],
            files: [
                .init(kind: .file, title: "Roadmap", url: URL(string: "https://example.invalid/roadmap")!, date: day)
            ],
            moreFiles: URL(string: "https://example.invalid/drive"))
    }
    func searchCustomEmoji(matching query: String) -> [CustomEmoji] {
        MentionQuery.filter(Self.customEmoji + [Self.searchOnlyEmoji], by: query)
    }
    /// A space's apps' commands; a person's DM has no apps, so only Google Chat's Meet link.
    func searchSlashCommands(in conversation: ConversationID, matching query: String, toApp: Bool) -> [SlashCommand] {
        slashCommandRequests.append((query, toApp))
        let space = rooms.first { $0.id == conversation }?.kind == .space
        let commands = space ? Self.slashCommands + [Self.createIssueCommand] : []
        return ([Self.meetLink] + commands).filter {
            query.isEmpty || $0.label.lowercased().contains(query.lowercased())
        }
    }
    func setReaction(_ emoji: String, custom: CustomEmoji?, for id: MessageID, present: Bool) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        var reactions = history[index].reactions
        if let match = reactions.firstIndex(where: { $0.emoji == emoji }) {
            if present {
                reactions[match].people.insert(Self.me.id)
            } else {
                reactions[match].people.remove(Self.me.id)
            }
        } else if present {
            reactions.append(Reaction(emoji: emoji, people: [Self.me.id], custom: custom))
        }
        history[index].reactions = reactions.filter { !$0.people.isEmpty }
        continuation.yield(.messageUpserted(history[index]))
    }
    func reactors(of id: MessageID, emoji: String, custom: CustomEmoji?) -> [Person] {
        reactorRequests += 1
        let everyone = peopleByID(adding: [Self.me])
        let ids = history.first { $0.id == id }?.reactions.first { $0.emoji == emoji }?.people ?? []
        return ids.sorted().map { everyone[$0] ?? Person(id: $0, name: "Unknown") }
    }
    func markRead(_ conversation: ConversationID) throws {
        if failNextRead {
            failNextRead = false
            throw AuthFailure.http(400)
        }
        markedRead.append(conversation)
        if let index = rooms.firstIndex(where: { $0.id == conversation }) { rooms[index].unread = 0 }
        continuation.yield(.readStateChanged(conversation, unread: 0))
    }
    /// A sidebar action: recorded in `changes` and applied to `rooms`, so a refresh shows it as the server would.
    private func change(_ name: String, _ id: ConversationID, _ edit: (inout Conversation) -> Void) async throws {
        changes.append("\(name) \(id)")
        if latency > .zero { try? await Task.sleep(for: latency) }
        if failNextChange {
            failNextChange = false
            throw URLError(.networkConnectionLost)
        }
        if let index = rooms.firstIndex(where: { $0.id == id }) { edit(&rooms[index]) }
    }
    func markRead(thread: ThreadID, upTo time: Date) { threadsRead.append(thread) }
    /// As the server does it: the THREAD_FOLLOWED label event follows the change.
    func setFollowing(_ following: Bool, for thread: ThreadID) async throws {
        changes.append("\(following ? "follow" : "unfollow") \(thread)")
        if latency > .zero { try? await Task.sleep(for: latency) }
        if failNextChange {
            failNextChange = false
            throw URLError(.networkConnectionLost)
        }
        continuation.yield(.threadFollowChanged(thread, following: following))
    }
    func setSidebarPinned(_ pinned: Bool, for conversation: ConversationID) async throws {
        try await change(pinned ? "pin" : "unpin", conversation) { $0.pinned = pinned }
    }
    func setMuted(_ muted: Bool, for conversation: ConversationID) async throws {
        try await change(muted ? "mute" : "unmute", conversation) { $0.muted = muted }
    }
    func setNotificationLevel(_ level: NotificationLevel, muted: Bool, for conversation: ConversationID) async throws {
        try await change("level \(level.rawValue)\(muted ? " muted" : "")", conversation) {
            $0.notificationLevel = level
        }
    }
    func markUnread(_ conversation: ConversationID) async throws {
        try await change("unread", conversation) { $0.unread = max($0.unread, 1) }
    }
    func markUnread(from message: Message) async throws {
        try await change("unread from \(message.id)", message.conversationID) { $0.unread = max($0.unread, 1) }
    }
    func leave(_ conversation: ConversationID) async throws {
        try await change("leave", conversation) { _ in }
        rooms.removeAll { $0.id == conversation }
    }
    /// I manage every space and group but General, where I am a plain member.
    func permissions(in conversation: ConversationID) -> ConversationPermissions {
        let typing = !typingDisallowed.contains(conversation)
        let emoji = customEmojiAllowed[conversation]
        guard let room = rooms.first(where: { $0.id == conversation }), room.kind != .direct, room.id != "general"
        else { return .init(typing: typing, customEmoji: emoji) }
        return ConversationPermissions(
            editProfile: true, manageMembers: true, typing: typing, editDetails: true, deleteSpace: true,
            changeRoles: true, changeManagers: true, toggleHistory: true, customEmoji: emoji)
    }
    func sidebarSections() -> [SidebarSection] { sections }
    func createSection(named name: String, at position: Int) async throws -> SidebarSection {
        let made = SidebarSection(kind: .custom, key: "k\(sections.count + 1)", name: name, position: position)
        sections.append(made)
        changes.append("section \(name)")
        return made
    }
    func renameSection(_ section: SidebarSection, to name: String) async throws {
        if let index = sections.firstIndex(of: section) { sections[index].name = name }
    }
    func moveSection(_ section: SidebarSection, to position: Int) async throws {
        if let index = sections.firstIndex(of: section) { sections[index].position = position }
    }
    func deleteSection(_ section: SidebarSection) async throws {
        sections.removeAll { $0.key == section.key }
        for index in rooms.indices where rooms[index].section == section.key { rooms[index].section = nil }
    }
    func moveConversation(_ conversation: ConversationID, to section: String?, from previous: String?) async throws {
        try await change("move to \(section ?? "default")", conversation) { $0.section = section }
    }
    func setPersonBlocked(_ blocked: Bool, for person: PersonID, dm: ConversationID?, report: Bool) async throws {
        changes.append("\(blocked ? "block" : "unblock") \(person)")
        if blocked { self.blocked.insert(person) } else { self.blocked.remove(person) }
    }
    func setSpaceBlocked(_ blocked: Bool, for space: ConversationID, report: Bool) async throws {
        try await change(blocked ? "block" : "unblock", space) { _ in }
    }
    func blockedPeople() -> [PersonID] { blocked.sorted() }
    func blockedSpaces() -> [BlockedSpace] { [] }
    func reportMessage(_ message: Message, reason: ReportReason, explanation: String) async throws {
        reports.append((message.id, reason))
    }
    func createSpace(name: String, emoji: String?) async throws -> Conversation {
        let room = Conversation(
            id: ConversationID("space/" + UUID().uuidString), name: name, kind: .space, members: [Self.me], emoji: emoji
        )
        rooms.insert(room, at: 0)
        return room
    }
    func deleteSpace(_ conversation: ConversationID) async throws {
        try await change("delete", conversation) { _ in }
        rooms.removeAll { $0.id == conversation }
    }
    func updateDetails(_ conversation: ConversationID, description: String, guidelines: String) async throws {
        try await change("details", conversation) {
            $0.description = description
            $0.guidelines = guidelines
        }
    }
    func setRole(_ role: MemberRole, for person: PersonID, in conversation: ConversationID) async throws {
        try await change("role \(role.rawValue) \(person)", conversation) { _ in }
        memberRoles[conversation, default: [:]][person] = role
    }
    func setHistory(_ on: Bool, for conversation: ConversationID) async throws {
        try await change(on ? "history on" : "history off", conversation) { $0.historyOff = !on }
    }
    func roles(in conversation: ConversationID) -> [PersonID: MemberRole] { memberRoles[conversation] ?? [:] }
    func updateProfile(_ conversation: ConversationID, name: String?, emoji: String?) async throws {
        if let name { try await change("rename \(name)", conversation) { $0.name = name } }
        if let emoji { try await change("emoji \(emoji)", conversation) { $0.emoji = emoji } }
    }
    func addMembers(_ people: [PersonID], to conversation: ConversationID) async throws {
        let everyone = peopleByID(adding: directory)
        try await change("add \(people.map(\.rawValue).joined(separator: ","))", conversation) { room in
            room.members += people.filter { id in !room.members.contains { $0.id == id } }.map {
                everyone[$0] ?? Person(id: $0, name: $0.rawValue)
            }
        }
    }
    func removeMember(_ person: PersonID, from conversation: ConversationID) async throws {
        try await change("remove \(person)", conversation) { $0.members.removeAll { $0.id == person } }
    }
    func setHidden(_ hidden: Bool, for conversation: ConversationID) async throws {
        try await change(hidden ? "hide" : "unhide", conversation) { $0.hidden = hidden ? .now : nil }
    }
    // ponytail: From, dates and images only; the other chips match everything here.
    func searchMessages(matching query: String, filters: SearchFilters, cursor: String?) -> SearchPage {
        SearchPage(
            messages: history.filter { message in
                (query.isEmpty || message.text.localizedCaseInsensitiveContains(query))
                    && (filters.from.isEmpty || filters.from.contains { $0.id == message.sender.id })
                    && (filters.saidIn.isEmpty || filters.saidIn.contains(message.conversationID))
                    && filters.after.map { message.createdAt >= $0 } ?? true
                    && filters.before.map { message.createdAt < $0 } ?? true
                    && (!filters.has.contains(.image) || message.attachments.contains { $0.kind == .image })
            })
    }
    func sendTyping(in conversation: ConversationID, thread: ThreadID?) throws {
        let scope = "\(conversation.rawValue)/\(thread?.rawValue ?? "timeline")"
        typingSent.append(scope)
        if typingRefused.contains(scope) { throw AuthFailure.http(403) }
    }
    func watch(_ conversations: Set<ConversationID>) { watched.append(conversations) }
    func fetchPresence(_ people: [PersonID]) {
        presenceRequests.append(people)
        let everyone = peopleByID()
        for id in people {
            if let person = everyone[id] {
                if person.presence != nil { presenceAnswered.insert(id) }
                continuation.yield(.presenceChanged(id, person.presence, status: nil))
            }
        }
    }
    func setDoNotDisturb(for duration: TimeInterval) -> OwnStatus {
        ownStatus.availability = .doNotDisturb(until: .now.addingTimeInterval(duration))
        return ownStatus
    }
    func setAway(_ away: Bool) throws -> OwnStatus {
        if failNextChange {
            failNextChange = false
            throw URLError(.networkConnectionLost)
        }
        ownStatus.availability = away ? .away : .automatic
        return ownStatus
    }
    func setCustomStatus(_ status: CustomStatus?) -> OwnStatus {
        ownStatus.custom = status
        return ownStatus
    }
    func searchPeople(matching query: String) -> [Person] {
        let everyone = peopleByID(adding: directory).values
        let words = query.trimmingCharacters(in: .whitespaces)
        return everyone.filter { person in
            person.id != Self.me.id
                && (words.isEmpty || person.name.localizedCaseInsensitiveContains(words)
                    || person.email?.localizedCaseInsensitiveContains(words) == true)
        }
        .sorted { $0.name < $1.name }
    }
    func directMessage(with ids: [PersonID]) -> Conversation {
        directMessageRequests.append(ids)
        let others = Set(ids).subtracting([Self.me.id])
        if let room = rooms.first(where: {
            $0.kind != .space && Set($0.members.map(\.id)).subtracting([Self.me.id]) == others
        }) {
            return room
        }
        let everyone = peopleByID(adding: directory)
        let members = ids.map {
            everyone[$0] ?? Person.invitedEmail($0).map(Person.invite(email:)) ?? Person(id: $0, name: $0.rawValue)
        }
        let room = Conversation(
            id: ConversationID("dm-" + ids.map(\.rawValue).joined(separator: "-")),
            name: members.map(\.name).sorted().joined(separator: ", "),
            kind: members.count == 1 ? .direct : .group, members: [Self.me] + members)
        rooms.insert(room, at: 0)
        return room
    }
    func searchSpaces(matching query: String) throws -> [SpaceListing] {
        if failDirectory {
            failDirectory = false
            throw URLError(.notConnectedToInternet)
        }
        return listings.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { listing in
                var listing = listing
                listing.joined = rooms.contains { $0.id == listing.id }
                return listing
            }
    }
    /// What the history shares, as the server would list it (one page).
    func shared(_ category: SharedCategory, in conversation: ConversationID, after: SharedContent.Item?) -> SharedPage {
        let content = SharedContent(history.filter { $0.conversationID == conversation })
        let items =
            switch category {
            case .media: content.media
            case .files: content.files
            case .links: content.links
            }
        return SharedPage(items: after == nil ? items : [], hasMore: false)
    }
    func join(_ space: SpaceListing) -> Conversation {
        joined.append(space.id)
        let room = Conversation(id: space.id, name: space.name, kind: .space, members: [Self.me], emoji: space.emoji)
        rooms.insert(room, at: 0)
        return room
    }
    func setStarred(_ starred: Bool, for id: MessageID) async throws {
        changes.append("\(starred ? "star" : "unstar") \(id)")
        if latency > .zero { try? await Task.sleep(for: latency) }
        if failNextChange {
            failNextChange = false
            throw URLError(.networkConnectionLost)
        }
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].starred = starred
        continuation.yield(.messageUpserted(history[index]))
    }
    func setBoardPinned(_ pinned: Bool, for id: MessageID) async throws {
        changes.append("\(pinned ? "pin" : "unpin") \(id)")
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].pinned = pinned
        continuation.yield(.messageUpserted(history[index]))
    }
    func dndSchedules(timeZone: String) -> DndSchedules { schedules }
    func setDndSchedules(_ schedules: DndSchedules) throws {
        if failNextChange {
            failNextChange = false
            throw URLError(.networkConnectionLost)
        }
        self.schedules = schedules
    }
    func boardMessages(in conversation: ConversationID) -> [Message] {
        history.filter { $0.conversationID == conversation && $0.pinned }
    }
    /// Home's thread rows: every thread with a reply, the General one unread.
    func homeThreads() -> [HomeThread] {
        if let serverHome { return serverHome }
        return history.filter { $0.replyCount > 0 && $0.threadID == nil }.compactMap { head in
            guard
                let latest = history.filter({ $0.threadID == ThreadID(head: head.id) }).max(by: {
                    $0.createdAt < $1.createdAt
                })
            else { return nil }
            return HomeThread(
                id: ThreadID(head: head.id), conversationID: head.conversationID, head: head, latest: latest,
                unread: head.id == "g1", time: latest.createdAt)
        }.sorted { $0.time > $1.time }
    }
    /// Every starred message, or every one that names me, newest first, in one page.
    func shortcut(_ shortcut: Shortcut, cursor: String?) -> SearchPage {
        let found = history.filter {
            shortcut == .starred ? $0.starred : NotificationPolicy.mentions($0, me: Self.me.id)
        }
        return SearchPage(messages: cursor == nil ? found.sorted { $0.createdAt > $1.createdAt } : [])
    }
    func drafts() -> [ServerDraft] { serverDrafts }
    func saveDraft(_ draft: ServerDraft) async throws -> ServerDraft {
        if draft.schedule != nil {  // a scheduled message
            var saved = draft
            saved.id = UUID().uuidString
            saved.updatedAt = .now
            scheduledMessages.append(saved)
            return saved
        }
        draftWrites.append(
            "\(draft.id.isEmpty ? "create" : "update") \(draft.conversationID)/\(draft.threadID ?? "timeline")")
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
        if draft.schedule != nil {
            scheduledMessages.removeAll { $0.id == draft.id }
            return
        }
        draftWrites.append("delete \(draft.conversationID)/\(draft.threadID ?? "timeline")")
        if failDraftWrites { throw URLError(.networkConnectionLost) }
        serverDrafts.removeAll { $0.id == draft.id }
    }
    func scheduled() -> [ServerDraft] { scheduledMessages }
    func reschedule(_ message: ServerDraft, to date: Date) -> ServerDraft {
        var moved = message
        moved.schedule = .init(at: date)
        if let index = scheduledMessages.firstIndex(where: { $0.id == message.id }) { scheduledMessages[index] = moved }
        return moved
    }
    /// A card action: the app answers by updating the message, as a documents app does when a reply is posted: the reply
    /// joins the comment, or the comment is resolved.
    func clickCard(_ id: MessageID, card: String?, action: Data, inputs: [Card.Input]) async throws -> Message? {
        cardClicks.append(
            ([id.rawValue] + (card.map { ["card=\($0)"] } ?? []) + inputs.map { "\($0.name)=\($0.value)" }).joined(
                separator: " "))
        if failNextChange {
            failNextChange = false
            throw URLError(.networkConnectionLost)
        }
        if let why = cardRefusal {
            cardRefusal = nil
            throw DynamiteError.appRefused(why)
        }
        guard let index = history.firstIndex(where: { $0.id == id }) else { return nil }
        history[index].edited = true
        if var card = history[index].attachments.first?.card,
            let input = card.sections.firstIndex(where: { $0.contains { if case .field = $0 { true } else { false } } })
        {
            let function = CardActionPayload.function(of: action)
            if function == "RESOLVE_COMMENT" {
                card.sections.replaceSubrange(
                    input...,
                    with: [
                        [.text("Dave resolved this comment", [TextStyleRange(style: .italic, start: 0, length: 26)])]
                    ])
            } else if let reply = inputs.first?.value, !reply.isEmpty {
                card.sections.insert(
                    [.row(icon: nil, round: true, label: Self.me.name, text: reply, formatting: [])], at: input)
            }
            history[index].attachments[0].card = card
        }
        return history[index]
    }
    /// The code-review app's "Create issue" dialog: a title it requires and a priority. Created, the issue arrives as a
    /// message from the app and the dialog closes with its note.
    func dialog(_ step: DialogStep, _ context: DialogContext, action: Data?, inputs: [Card.Input]) async throws
        -> DialogAnswer
    {
        dialogSteps.append(
            (["\(step)", context.anchor, "app=\(context.app)"] + inputs.map { "\($0.name)=\($0.value)" }).joined(
                separator: " "))
        if failNextChange {
            failNextChange = false
            throw URLError(.networkConnectionLost)
        }
        if let answer = dialogAnswer {
            dialogAnswer = nil
            return answer
        }
        switch step {
        case .open: return .show(Self.createIssue)
        case .cancel: return .close(nil)
        case .submit where CardActionPayload.function(of: action ?? Data()) == "cancel": return .close(nil)
        case .submit:
            let title = inputs.first { $0.name == "title" }?.value.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { return .invalid("Give the issue a title.") }
            let conversation =
                switch context.source {
                case .command(_, let conversation): conversation
                case .message(let id): history.first { $0.id == id }?.conversationID ?? "design"
                }
            let issue = Message(
                id: MessageID("issue\(history.count)"), conversationID: conversation, sender: Self.shipyard,
                text: "Issue #43 opened: \(title)", createdAt: .now)
            history.append(issue)
            push(.messageUpserted(issue))
            return .close("Issue #43 created.")
        }
    }
    /// Nothing leaves the Mac: the file stays where it is and the token just names it.
    func upload(_ attachment: Attachment, to conversation: ConversationID, thread: ThreadID?) async throws -> Attachment
    {
        uploaded.append(attachment)
        if latency > .zero { try? await Task.sleep(for: latency) }
        if failNextUpload {
            failNextUpload = false
            throw URLError(.networkConnectionLost)
        }
        var done = attachment
        done.uploadToken = "fake-\(attachment.name)"
        return done
    }
    /// A generated gradient for images and previews; a tone for voice messages; a small text file otherwise.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) throws -> Data {
        if attachment.kind == .voice {
            let rate = 8_000.0
            let seconds = attachment.voice?.duration ?? 2
            return Self.wav(
                (0..<Int(rate * seconds)).map { sample in
                    let time = Double(sample) / rate
                    return Int16(6_000 * abs(sin(time * 2.5)) * sin(2 * .pi * 220 * time))
                })
        }
        guard thumbnail || attachment.kind != .file else { return Data("Parley demo file: \(attachment.name)\n".utf8) }
        let size = NSSize(width: attachment.width ?? 320, height: attachment.height ?? 240)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 45)
            return true
        }
        guard let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
    // The two failures `send` and `upload` check, kept beside them as their flags are private.
    func simulateSendFailure() { failNextSend = true }
    func simulateUploadFailure() { failNextUpload = true }
}
