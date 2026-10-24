import Foundation

// Naming, after the Swift API Design Guidelines (clarity at the point of use):
// - The base name says what the call does; the thing it acts on comes first, unlabeled when the base name names it
//   (`leave(_:)`, `deleteMessage(_:)`, `deleteDraft(_:)`).
// - Other arguments are labeled by their role: `in` the conversation a call reads from or acts within, `to` a destination,
//   `from` a source or a starting point, `of` an owner, `matching` a typed query.
// - Setters are `set<State>(_ value:, for target:)`. When one word names two features, the base name says which:
//   `setSidebarPinned` (a conversation in my sidebar) and `setBoardPinned` (a message on the board),
//   `setPersonBlocked` and `setSpaceBlocked`.
// - Read state is `markRead`/`markUnread`, with the scope in the label: `markRead(_:)` a conversation,
//   `markRead(thread:upTo:)`, `markUnread(_:)`, `markUnread(from:)`.
// - Reads are nouns (`messages(in:)`, `members(of:)`); lookups by a typed query are `search<Things>(matching:)`.

/// Everything the store asks of Google Chat. `DynamiteBackend` talks to Google; `FakeBackend` is the demo and the tests'.
public typealias ChatBackend = ConnectionBackend & TimelineBackend & MessagingBackend & ConversationBackend
    & StatusBackend
    & LookupBackend & DraftsBackend & CardsBackend

/// The session with Google Chat: connecting, the events it pushes, and which conversations it pushes them for.
public protocol ConnectionBackend: Sendable {
    var events: AsyncStream<ChatEvent> { get }
    /// Verifies the session and returns the signed-in person.
    func connect() async throws -> Person
    /// The conversations open on screen, as a full replacement set: typing is only pushed for these.
    func watch(_ conversations: Set<ConversationID>) async
}

/// Reading messages: a conversation's history and threads, search, shared content, Home and the shortcuts' lists.
public protocol TimelineBackend: Sendable {
    func messages(in conversation: ConversationID, thread: ThreadID?, before: Date?) async throws -> MessagePage
    /// The page around `message`, as web Chat opens an old search result; older pages follow with `messages(in:thread:before:)`.
    func messages(around message: MessageID, in conversation: ConversationID) async throws -> MessagePage
    /// A space's threads with replies, newest reply first, as Google Chat's Active threads lists them; the list is then
    /// marked seen.
    func threads(in conversation: ConversationID) async throws -> [ThreadSummary]
    /// The next page after the newest one loaded since `messages(around:in:)`.
    func newerMessages(in conversation: ConversationID) async throws -> MessagePage
    /// Messages matching `query` and `filters`: in every conversation, or only those `filters.saidIn` names.
    func searchMessages(matching query: String, filters: SearchFilters, cursor: String?) async throws -> SearchPage
    /// The media, files or links shared in a conversation, newest first, without its history;
    /// `after` is the last item of the previous page.
    func shared(_ category: SharedCategory, in conversation: ConversationID, after: SharedContent.Item?) async throws
        -> SharedPage
    /// The messages on a conversation's board, as Google Chat's Board panel lists them.
    func boardMessages(in conversation: ConversationID) async throws -> [Message]
    /// One page of a shortcut's messages, newest first; `cursor` is the previous page's.
    func shortcut(_ shortcut: Shortcut, cursor: String?) async throws -> SearchPage
    /// The threads Home lists, newest first, as the last `conversations()` brought them.
    func homeThreads() async -> [HomeThread]
    /// Everyone who reacted to a message with `emoji`, as the server lists them (up to 100).
    func reactors(of id: MessageID, emoji: String, custom: CustomEmoji?) async throws -> [Person]
    /// Thumbnail (or the full file when there is none) for display; `thumbnail: false` for the original.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data
}

/// Writing messages and their state: send, edit, delete, react, star, pin, upload, typing, read and unread.
public protocol MessagingBackend: Sendable {
    func send(_ draft: MessageDraft, to conversation: ConversationID, thread: ThreadID?) async throws -> Message
    /// Makes a Google Meet meeting for the conversation and posts it, as Google Chat's "Send a Meet link" does.
    func sendMeetLink(in conversation: ConversationID) async throws -> Message
    func edit(_ id: MessageID, text: String, formatting: [TextStyleRange]) async throws
    func deleteMessage(_ id: MessageID) async throws
    /// `custom`: the reaction's custom emoji, which goes back to the server as it came.
    func setReaction(_ emoji: String, custom: CustomEmoji?, for id: MessageID, present: Bool) async throws
    func markRead(_ conversation: ConversationID) async throws
    /// Marks a thread read up to its newest reply, so it reads as read on every device.
    func markRead(thread: ThreadID, upTo time: Date) async throws
    /// Follows a thread (its replies notify me) or unfollows it.
    func setFollowing(_ following: Bool, for thread: ThreadID) async throws
    /// Marks the newest message unread until the conversation is read again.
    func markUnread(_ conversation: ConversationID) async throws
    /// Marks a conversation, or for a reply its thread, unread from that message on.
    func markUnread(from message: Message) async throws
    /// Reports a message to the organisation's admin.
    func reportMessage(_ message: Message, reason: ReportReason, explanation: String) async throws
    /// Uploads a local file (`Attachment.localFile`) for a message in `conversation`; returns it with `uploadToken` set.
    func upload(_ attachment: Attachment, to conversation: ConversationID, thread: ThreadID?) async throws -> Attachment
    /// "I'm typing" (there is no "stopped": receivers time it out). Throttling is the caller's.
    func sendTyping(in conversation: ConversationID, thread: ThreadID?) async throws
    /// Stars a message for me, or unstars it.
    func setStarred(_ starred: Bool, for id: MessageID) async throws
    /// Pins a message to its conversation's board, or takes it off; the board is shared by every member.
    func setBoardPinned(_ pinned: Bool, for id: MessageID) async throws
}

/// The conversation list and each conversation's settings: sidebar sections, membership, roles, history, blocking, spaces.
public protocol ConversationBackend: Sendable {
    func conversations() async throws -> [Conversation]
    /// Pins (stars) a conversation in my sidebar, or unpins it.
    func setSidebarPinned(_ pinned: Bool, for conversation: ConversationID) async throws
    /// Mutes a conversation's notifications, or unmutes them; the notification level stays as it was.
    func setMuted(_ muted: Bool, for conversation: ConversationID) async throws
    /// Sets when a conversation notifies me; `muted` is resent as it is, since the server stores both together.
    func setNotificationLevel(_ level: NotificationLevel, muted: Bool, for conversation: ConversationID) async throws
    /// Leaves a space or group conversation.
    func leave(_ conversation: ConversationID) async throws
    /// What I may change in a space or group.
    func permissions(in conversation: ConversationID) async throws -> ConversationPermissions
    /// Renames a space or group and/or sets its emoji; nil leaves that one as it is.
    func updateProfile(_ conversation: ConversationID, name: String?, emoji: String?) async throws
    /// Adds people to a space or group; a space invites them.
    func addMembers(_ people: [PersonID], to conversation: ConversationID) async throws
    /// Removes someone else from a space or group.
    func removeMember(_ person: PersonID, from conversation: ConversationID) async throws
    /// Hides a conversation from my sidebar, or shows it again.
    func setHidden(_ hidden: Bool, for conversation: ConversationID) async throws
    /// A new space with me as its only member, as Google Chat's Create a space makes it.
    func createSpace(name: String, emoji: String?) async throws -> Conversation
    /// Deletes a space and all its messages for everyone.
    func deleteSpace(_ conversation: ConversationID) async throws
    /// The sidebar's sections from the last `conversations()` read, in my order (empty when Google sent none).
    func sidebarSections() async -> [SidebarSection]
    func createSection(named name: String, at position: Int) async throws -> SidebarSection
    func renameSection(_ section: SidebarSection, to name: String) async throws
    func moveSection(_ section: SidebarSection, to position: Int) async throws
    func deleteSection(_ section: SidebarSection) async throws
    /// Moves a conversation into a custom section (its key), or back to its default one (nil), from `previous`.
    func moveConversation(_ conversation: ConversationID, to section: String?, from previous: String?) async throws
    /// Blocks or unblocks a person (and their DM with me), optionally reporting them to Google.
    func setPersonBlocked(_ blocked: Bool, for person: PersonID, dm: ConversationID?, report: Bool) async throws
    /// Blocks or unblocks a space, optionally reporting it to Google.
    func setSpaceBlocked(_ blocked: Bool, for space: ConversationID, report: Bool) async throws
    func blockedPeople() async throws -> [PersonID]
    func blockedSpaces() async throws -> [BlockedSpace]
    /// A space's description and guidelines, saved together as Google Chat saves them.
    func updateDetails(_ conversation: ConversationID, description: String, guidelines: String) async throws
    func setRole(_ role: MemberRole, for person: PersonID, in conversation: ConversationID) async throws
    /// History on keeps messages; off has Google delete new ones after a day.
    func setHistory(_ on: Bool, for conversation: ConversationID) async throws
    /// Each member's role, from the last `members(of:)` read.
    func roles(in conversation: ConversationID) async -> [PersonID: MemberRole]
    /// Everyone who has joined `conversation`, for @-mentions.
    func members(of conversation: ConversationID) async throws -> [Person]
    /// The DM with these people (one: 1:1, several: a group DM), found or else created.
    func directMessage(with people: [PersonID]) async throws -> Conversation
    /// Spaces in the directory matching `query`.
    func searchSpaces(matching query: String) async throws -> [SpaceListing]
    /// Joins a space and returns it as a conversation.
    func join(_ space: SpaceListing) async throws -> Conversation
}

/// Presence and my own status: Do Not Disturb, away, custom status and the Do Not Disturb schedules.
public protocol StatusBackend: Sendable {
    /// One batched lookup; answers arrive as `.presenceChanged` events.
    func fetchPresence(_ people: [PersonID]) async throws
    /// Do Not Disturb for `duration` seconds; it ends away. Each status call returns my status as the server saved it.
    func setDoNotDisturb(for duration: TimeInterval) async throws -> OwnStatus
    /// Away, or (false) automatic, which also ends Do Not Disturb.
    func setAway(_ away: Bool) async throws -> OwnStatus
    /// Sets my custom status, or clears it (nil).
    func setCustomStatus(_ status: CustomStatus?) async throws -> OwnStatus
    /// The account's do not disturb schedules, with times in `timeZone`; saving replaces the whole set.
    func dndSchedules(timeZone: String) async throws -> DndSchedules
    func setDndSchedules(_ schedules: DndSchedules) async throws
}

/// Lookups for the composer and people's cards: people, the directory, Drive files, custom emoji, apps and slash commands.
public protocol LookupBackend: Sendable {
    /// People to start a conversation with, matching `query` by name or email; never me.
    func searchPeople(matching query: String) async throws -> [Person]
    /// People in the organisation's directory matching `query`, members of the conversation or not, for the @ list.
    func searchDirectory(matching query: String) async throws -> [Person]
    /// The time zone `email`'s owner set in Google Calendar, which their card shows as local time; nil when not shared.
    func timeZone(email: String) async throws -> TimeZone?
    /// The job title of `email`'s owner, from Google Contacts, which their card shows; `name` helps the lookup.
    func jobTitle(email: String, name: String) async throws -> String?
    /// What `id`'s detailed view shows, from Google Contacts: their reporting line, what we recently shared, and their files.
    func personDetails(id: PersonID, email: String?) async throws -> PersonDetails
    /// The organisation's custom emoji that can be sent (enabled ones), every page.
    func customEmojis() async throws -> [CustomEmoji]
    /// The organisation's enabled custom emoji whose shortcode matches `query` (typed after the ":"), as the server finds them.
    func searchCustomEmoji(matching query: String) async throws -> [CustomEmoji]
    /// The conversation's own apps whose name matches `query`, for the @ list's Apps section.
    func searchApps(in conversation: ConversationID, matching query: String) async throws -> [Person]
    /// Drive files for the @ list's Files section: recent ones for an empty query, else ones matching it.
    func searchDriveFiles(matching query: String) async throws -> [DriveFile]
    /// The commands `conversation` offers whose name contains `query` (typed after the "/"; empty: the first page of all):
    /// its apps' and Google Chat's "Send a Meet link"; in an app's DM (`toApp`), that app's only.
    func searchSlashCommands(in conversation: ConversationID, matching query: String, toApp: Bool) async throws
        -> [SlashCommand]
}

/// Server drafts and scheduled messages, as Google Chat keeps them for every device.
public protocol DraftsBackend: Sendable {
    /// Every server draft.
    func drafts() async throws -> [ServerDraft]
    /// Creates the draft when its `id` is empty, else replaces its text and formatting; returns it as saved (id, update time).
    func saveDraft(_ draft: ServerDraft) async throws -> ServerDraft
    func deleteDraft(_ draft: ServerDraft) async throws
    /// Every scheduled message; `saveDraft` schedules one (a draft with a `schedule` and no id) and `deleteDraft` cancels it.
    func scheduled() async throws -> [ServerDraft]
    func reschedule(_ message: ServerDraft, to date: Date) async throws -> ServerDraft
}

/// Apps' cards and dialogs: a card's button, and a dialog's steps.
public protocol CardsBackend: Sendable {
    /// Sends a card button's action and the card's inputs back to its app; returns the message as the app updated it.
    func clickCard(_ id: MessageID, card: String?, action: Data, inputs: [Card.Input]) async throws -> Message?
    /// One of a dialog's requests (`DialogStep`): `action` is the pressed button's (nil when a slash command opens it or
    /// on close), `inputs` the dialog's (or, on open, the card's).
    func dialog(_ step: DialogStep, _ context: DialogContext, action: Data?, inputs: [Card.Input]) async throws
        -> DialogAnswer
}
