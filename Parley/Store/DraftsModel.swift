import Foundation
import ParleyDomain

/// What each composer holds, by draft key: its text and formatting, files, the message it quotes or edits, Google's copy of
/// its draft and the bookkeeping that keeps the two in step, and the messages scheduled to send later. `ChatStore`'s
/// actions save, list and send through the backend; this model holds the state and the rules that need nothing else.
@MainActor @Observable final class DraftsModel {
    /// Each composer's text, by draft key.
    var text: [String: String] = [:] {
        didSet {
            let scopes = Set(text.filter { !Self.blank($0.value) }.keys)
            if scopes != drafted { drafted = scopes }
        }
    }
    /// The draft keys whose composer holds text. It changes only when a draft starts or is cleared, so a view showing
    /// "1 draft" reads this, not `text`, and doesn't update on every keystroke.
    private(set) var drafted: Set<String> = []
    var formatting: [String: [TextStyleRange]] = [:]  // per draft key, UTF-16 ranges into the draft text
    var attachments: [String: [Attachment]] = [:]  // per draft key, local files to upload on send (not cached across launches)
    var editing: [String: MessageID] = [:]  // per draft key: the sent message that composer is editing
    /// Per draft key being edited: the draft the edit borrowed the composer from, given back when the edit ends.
    var held: [String: (text: String, formatting: [TextStyleRange]?)] = [:]
    var quoting: [String: QuotedMessage] = [:]  // per draft key: the message the next send quotes (not cached across launches)
    /// A composer's send waiting for my answer, by scope: the names of the people its mentions would add, as Google Chat
    /// asks before adding them ("Add to this conversation?"). Answered with `ChatStore.send(conversation:thread:adding:)`.
    var addPrompts: [String: [String]] = [:]
    /// The mention types chosen when a message was sent, kept until it goes, so a retry doesn't add someone I declined.
    @ObservationIgnored var sendOutsiders: [MessageID: [PersonID: MessageDraft.Outsider]] = [:]

    // Server drafts: each composer's draft saved to Google too, so it follows the user to web and phone (see `ChatStore.syncDraft`).
    var server: [String: ServerDraft] = [:]  // per draft key: Google's copy, as last saved or heard of
    /// Messages Google sends later, soonest first: scheduled from a composer here or elsewhere (see `ChatStore.schedule`).
    var scheduled: [ServerDraft] = []
    @ObservationIgnored var edits: [String: Date] = [:]  // draft keys typed in since their last save, and when
    @ObservationIgnored var listed = false
    @ObservationIgnored var listing: Task<Bool, Never>?
    @ObservationIgnored var writes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var timers: [String: Task<Void, Never>] = [:]
    /// Drafts a send used up (Google drops them): a late echo of one never refills a composer.
    @ObservationIgnored var spent: Set<String> = []
    /// Sends per draft key: a save that started before the latest send finishes as a leftover, which is deleted.
    @ObservationIgnored var sends: [String: Int] = [:]

    static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Whether `scope` holds a sent message being edited, whose text is no draft.
    func isEditing(_ scope: String) -> Bool { editing[scope] != nil }
    /// Puts `text` in `scope`'s composer; true when it or its formatting changed.
    func set(_ text: String, formatting: [TextStyleRange], in scope: String) -> Bool {
        let changed = self.text[scope, default: ""] != text || self.formatting[scope, default: []] != formatting
        self.text[scope] = text
        self.formatting[scope] = formatting.isEmpty ? nil : formatting
        return changed
    }
    /// Google's copy fills the composer, which then has nothing left to save.
    func fill(_ scope: String, with draft: ServerDraft) {
        text[scope] = draft.text
        formatting[scope] = draft.formatting.isEmpty ? nil : draft.formatting
        edits[scope] = nil
    }
    func clear(_ scope: String) {
        text[scope] = nil
        formatting[scope] = nil
    }

    // MARK: Editing a sent message

    /// `scope`'s composer starts editing `message`: the draft it held is put aside (once), and a quote is dropped.
    func startEdit(_ message: MessageID, in scope: String) {
        if editing[scope] == nil { held[scope] = (text[scope] ?? "", formatting[scope]) }
        editing[scope] = message
        quoting[scope] = nil
    }
    /// Ends `scope`'s edit and gives back the draft it borrowed the composer from; false when it wasn't editing.
    func finishEdit(_ scope: String) -> Bool {
        guard editing.removeValue(forKey: scope) != nil else { return false }
        let kept = held.removeValue(forKey: scope)
        text[scope] = kept?.text ?? ""
        formatting[scope] = kept?.formatting
        return true
    }

    // MARK: Sending and scheduling

    /// A send takes the composer's draft: its timer stops, it has nothing left to save, and Google's copy (returned) is spent.
    func spend(_ scope: String) -> String? {
        timers.removeValue(forKey: scope)?.cancel()
        edits[scope] = nil
        let draft = server.removeValue(forKey: scope)?.id
        if let draft { spent.insert(draft) }
        sends[scope, default: 0] += 1
        return draft
    }
    /// Only text can wait, as on the web: no files, quote or forward, and not an edit.
    func canSchedule(_ scope: String) -> Bool {
        !Self.blank(text[scope] ?? "") && editing[scope] == nil && (attachments[scope] ?? []).isEmpty
            && quoting[scope] == nil
    }
    func scheduled(in conversation: ConversationID, thread: ThreadID?) -> [ServerDraft] {
        scheduled.filter { $0.conversationID == conversation && $0.threadID == thread }
    }
    func keepScheduled(_ message: ServerDraft) {
        scheduled.removeAll { $0.id == message.id }
        scheduled.append(message)
        scheduled.sort(by: Self.soonest)
    }
    static func soonest(_ lhs: ServerDraft, _ rhs: ServerDraft) -> Bool {
        (lhs.schedule?.at ?? .distantPast) < (rhs.schedule?.at ?? .distantPast)
    }
    /// Stops the saves and the listing still running, before the model is dropped.
    func cancel() {
        listing?.cancel()
        for task in Array(timers.values) + Array(writes.values) { task.cancel() }
    }
}
