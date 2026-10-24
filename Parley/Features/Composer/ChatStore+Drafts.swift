import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    func setDraft(_ text: String, formatting: [TextStyleRange] = [], conversation: ConversationID, thread: ThreadID?) {
        let scope = key(conversation, thread)
        let changed = drafting.set(text, formatting: formatting, in: scope)
        if changed, !drafting.isEditing(scope) {
            drafting.edits[scope] = now()
            scheduleDraftSave(scope)
        }  // an edit's text is no draft
        persist()
    }

    // MARK: Server drafts

    /// A draft key's conversation and thread, for a conversation the sidebar knows; nil for any other.
    private func place(_ scope: String) -> (ConversationID, ThreadID?)? {
        guard let room = rooms.conversations.first(where: { scope.hasPrefix($0.id.rawValue + "/") }) else { return nil }
        let rest = String(scope.dropFirst(room.id.rawValue.count + 1))
        return (room.id, rest == "timeline" ? nil : ThreadID(rest))
    }
    /// After a pause in typing, a draft Google doesn't have yet is created (or a cleared one deleted); after a longer
    /// idle, a changed one is updated too.
    private func scheduleDraftSave(_ scope: String) {
        drafting.timers[scope]?.cancel()
        drafting.timers[scope] = Task { [weak self, draftPause, draftIdle] in
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
        let scopes = drafting.listed ? drafting.edits.keys.sorted() : []  // before the first list the merge pushes them
        return Task { for scope in scopes { await syncDraft(scope) } }
    }
    /// Brings Google's copy of one composer's draft in line with the composer: created when it has text Google lacks, deleted
    /// when it is empty, updated (`updating`) when its text or formatting changed. One write at a time per composer; a
    /// failure keeps the text and the edit mark, so the next trigger tries again.
    func syncDraft(_ scope: String, updating: Bool = true) async {
        while let running = drafting.writes[scope] { await running.value }
        if !drafting.listed { guard await listDrafts() else { return } }
        guard !drafting.isEditing(scope), let (conversation, thread) = place(scope) else { return }
        let text = drafting.text[scope] ?? ""
        let formatting = drafting.formatting[scope] ?? []
        let held = drafting.server[scope]
        if DraftsModel.blank(text) ? held == nil : held.map({ $0.text == text && $0.formatting == formatting }) ?? false
        {
            drafting.edits[scope] = nil  // nothing to save
            return
        }
        if held != nil, !DraftsModel.blank(text), !updating { return }
        let sends = drafting.sends[scope, default: 0]
        let task = Task {
            do {
                if DraftsModel.blank(text), let held {
                    try await backend.deleteDraft(held)
                    if drafting.server[scope]?.id == held.id { drafting.server[scope] = nil }
                } else {
                    let saved = try await backend.saveDraft(
                        ServerDraft(
                            id: held?.id ?? "", conversationID: conversation, threadID: thread,
                            text: text, formatting: formatting))
                    if drafting.sends[scope, default: 0] != sends {
                        // The message went while this was on its way: Google now holds its old text as a draft. Undone.
                        drafting.spent.insert(saved.id)
                        try await backend.deleteDraft(saved)
                        drafting.writes[scope] = nil
                        return
                    }
                    drafting.server[scope] = saved
                }
                if drafting.text[scope] ?? "" == text, drafting.formatting[scope] ?? [] == formatting {
                    drafting.edits[scope] = nil
                }
            } catch {
                log.error("draft not saved: \(Redaction.redact(error.localizedDescription), privacy: .public)")
                _ = endedSession(error)
            }
            drafting.writes[scope] = nil
            persist()
        }
        drafting.writes[scope] = task
        await task.value
    }
    /// Drafts' Delete: the composer empties and Google's copy goes now, without waiting for a pause in typing.
    func deleteDraft(_ draft: ServerDraft) async {
        setDraft("", conversation: draft.conversationID, thread: draft.threadID)
        let scope = key(draft.conversationID, draft.threadID)
        drafting.timers[scope]?.cancel()
        await syncDraft(scope)
    }
    /// Google's drafts, merged with this Mac's: a draft only Google has fills its composer; one only this Mac has is pushed,
    /// unless it was saved before and Google no longer has it (sent or deleted elsewhere); when both have one, the newer
    /// wins, by Google's update time against the last local edit. False when the list failed; the next save asks again.
    @discardableResult func listDrafts() async -> Bool {
        if let running = drafting.listing { return await running.value }
        let listing = Task { () -> Bool in
            defer { drafting.listing = nil }
            let list: [ServerDraft]
            do { list = try await backend.drafts() } catch {
                log.error("drafts not listed: \(Redaction.redact(error.localizedDescription), privacy: .public)")
                _ = endedSession(error)
                return false
            }
            let known = drafting.server
            drafting.server = Dictionary(
                list.filter { !drafting.spent.contains($0.id) }.map { (key($0.conversationID, $0.threadID), $0) },
                uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
            drafting.listed = true
            var push: [String] = []
            for (scope, draft) in drafting.server where !drafting.isEditing(scope) {
                if let edited = drafting.edits[scope], edited > draft.updatedAt {
                    push.append(scope)
                } else {
                    drafting.fill(scope, with: draft)
                }
            }
            for (scope, text) in drafting.text
            where drafting.server[scope] == nil && !DraftsModel.blank(text) && !drafting.isEditing(scope) {
                if drafting.edits[scope] == nil, known[scope]?.text == text {
                    drafting.clear(scope)
                } else {
                    push.append(scope)
                }
            }
            for scope in push.sorted() { Task { await syncDraft(scope) } }
            persist()
            return true
        }
        drafting.listing = listing
        return await listing.value
    }
    /// How many drafts Drafts lists, from `drafting.drafted`: the sidebar's badge doesn't update on every keystroke.
    var draftCount: Int { drafting.drafted.filter { !drafting.isEditing($0) && place($0) != nil }.count }
    /// The Drafts shortcut: every composer holding a draft, newest first. `updatedAt` is when it last changed, here or on
    /// Google (`.distantPast` when unknown).
    func draftList() -> [ServerDraft] {
        drafting.text.compactMap { scope, text -> ServerDraft? in
            guard !DraftsModel.blank(text), !drafting.isEditing(scope), let (conversation, thread) = place(scope) else {
                return nil
            }
            let edited = drafting.edits[scope].flatMap { $0 == .distantPast ? nil : $0 }
            let server = drafting.server[scope]
            return ServerDraft(
                id: server?.id ?? "", conversationID: conversation, threadID: thread, text: text,
                formatting: drafting.formatting[scope] ?? [], updatedAt: edited ?? server?.updatedAt ?? .distantPast)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.conversationID < $1.conversationID : $0.updatedAt > $1.updatedAt }
    }
    // Scheduled send, as Google Chat's: the server keeps the message and sends it at its time.
    func listScheduled() async {
        do { drafting.scheduled = try await backend.scheduled().sorted(by: DraftsModel.soonest) } catch {
            log.error(
                "scheduled history.messages not listed: \(Redaction.redact(error.localizedDescription), privacy: .public)"
            )
            _ = endedSession(error)
        }
    }
    /// Only text can wait, as on the web: no files, quote or forward, and not an edit.
    func canSchedule(conversation: ConversationID, thread: ThreadID?) -> Bool {
        drafting.canSchedule(key(conversation, thread))
    }
    /// The composer's text goes to Google to send at `date`; the composer empties, which drops its own draft as a send does.
    func schedule(conversation: ConversationID, thread: ThreadID? = nil, at date: Date) async {
        guard canSchedule(conversation: conversation, thread: thread) else { return }
        let scope = key(conversation, thread)
        let (text, formatting) = Self.trimmed(drafting.text[scope, default: ""], drafting.formatting[scope] ?? [])
        do {
            drafting.keepScheduled(
                try await backend.saveDraft(
                    ServerDraft(
                        conversationID: conversation, threadID: thread, text: text,
                        formatting: formatting, schedule: .init(at: date))))
            setDraft("", conversation: conversation, thread: thread)
        } catch { report(error) }
    }
    /// Sends it now, naming it so Google drops it, as Google Chat's Send now does.
    func sendNow(_ message: ServerDraft) async {
        drafting.scheduled.removeAll { $0.id == message.id }
        drafting.spent.insert(message.id)
        await sendNew(
            message.text, formatting: message.formatting, serverDraft: message.id, conversation: message.conversationID,
            thread: message.threadID)
    }
    func reschedule(_ message: ServerDraft, to date: Date) async {
        do { drafting.keepScheduled(try await backend.reschedule(message, to: date)) } catch { report(error) }
    }
    func unschedule(_ message: ServerDraft) async {
        do {
            try await backend.deleteDraft(message)
            drafting.scheduled.removeAll { $0.id == message.id }
        } catch { report(error) }
    }
    /// The threads in `conversation` whose reply box holds a draft, for the "1 draft" under their first message.
    func threadsWithDrafts(in conversation: ConversationID) -> Set<ThreadID> {
        Set(
            drafting.drafted.compactMap { scope -> ThreadID? in
                guard !drafting.isEditing(scope), let (room, thread) = place(scope), room == conversation else {
                    return nil
                }
                return thread
            })
    }

    // MARK: Editing a sent message

    /// The message `conversation`'s composer (or its `thread`'s) is editing.
    func editingID(_ conversation: ConversationID, thread: ThreadID?) -> MessageID? {
        drafting.editing[key(conversation, thread)]
    }
    /// Leaving what the main window shows ends the edits in its composers (the conversation's and its thread pane's) and
    /// clears their text, which is the message's, not a draft. A thread in its own window keeps its edit.
    func endMainWindowEdits() {
        guard let room = navigation.selectedID else { return }
        for scope in [key(room, nil)] + (navigation.threadID.map { [key(room, $0)] } ?? []) { finishEdit(scope) }
    }
    /// Esc in an editing composer: the edit is dropped and the draft is back.
    func endEdit(conversation: ConversationID, thread: ThreadID?) { finishEdit(key(conversation, thread)) }
    /// Ends `scope`'s edit and gives back the draft it borrowed the composer from. The draft's sync state never changed
    /// (an edit is no draft), so nothing is saved or deleted on Google.
    func finishEdit(_ scope: String) {
        guard drafting.finishEdit(scope) else { return }
        persist()
    }
    func edit(_ message: Message) {
        guard message.sender.id == me.id, message.delivery == .sent else { return }
        let scope = key(message.conversationID, message.threadID)
        drafting.startEdit(message.id, in: scope)
        setDraft(
            message.text, formatting: message.formatting, conversation: message.conversationID, thread: message.threadID
        )
    }
}
