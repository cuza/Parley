import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

/// Presence actions that need more than `PresenceModel`: the backend, the open conversation, me.
extension ChatStore {
    func markActive(_ person: PersonID) {
        guard person != me.id else { return }
        presence.markActive(person, at: now())
    }
    func sweepTyping() { presence.sweepTyping(at: now()) }
    /// The app at work where this composer is (Ask Gemini "Collecting info"), for the typing bubble.
    func activity(_ conversation: ConversationID, thread: ThreadID?) -> PresenceModel.Activity? {
        presence.activities[key(conversation, thread)]
    }
    func typists(_ conversation: ConversationID, thread: ThreadID? = nil) -> [PersonID] {
        presence.typists(in: key(conversation, thread))
    }
    /// The composer's text changed: tell the others at most every 5 s per composer, never for blank text or while
    /// editing a sent message. There is no "stopped"; receivers time it out.
    func typed(_ text: String, conversation: ConversationID, thread: ThreadID?) async {
        let scope = key(conversation, thread)
        guard drafting.editing[scope] == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            presence.shouldSendTyping(in: scope, at: now())
        else { return }
        presence.typingSent[scope] = now()  // before any wait, so keystrokes meanwhile don't ask again
        // Whether Google lets me send typing here (a space's capability); asked once per space.
        if rooms.permissions[conversation] == nil { await loadPermissions(conversation) }
        guard rooms.permissions[conversation]?.typing != false else {
            log.notice("typing not sent: not allowed in this space")
            return
        }
        do {
            try await backend.sendTyping(in: conversation, thread: thread)
        } catch AuthFailure.http(403) {
            presence.typingRefused.insert(scope)
        } catch {
        }
    }
    // ponytail: only the main window's conversation is watched; add the extra windows' ones if typing is wanted there too.
    func watchOpen() async {
        let open: Set<ConversationID> = navigation.selectedID.map { [$0] } ?? []
        guard open != presence.watching else { return }
        presence.watching = open
        await backend.watch(open)
    }
    // ponytail: the 50 most recent 1:1 DMs; page through the rest if the sidebar shows more dots than that.
    /// Asks, in one batch, for everyone whose presence is over 60 s old among 1:1 partners and the open conversation's members.
    func refreshPresence() async {
        let partners = rooms.conversations.compactMap(partner).prefix(50)
        let open = navigation.selectedID.map(mentionCandidates)?.map(\.id) ?? []
        let stale = presence.stale(Set(partners + open).subtracting([me.id, ""]), at: now())
        guard !stale.isEmpty else { return }
        for id in stale { presence.fetched[id] = now() }  // also spaces out retries after a failure
        try? await backend.fetchPresence(stale.sorted())
    }
    /// Each reader under my newest message their read time covers: DMs and group DMs only.
    func seen(in conversation: Conversation) -> [MessageID: [PersonID]] {
        guard conversation.kind != .space, let reads = presence.readReceipts[conversation.id] else { return [:] }
        let mine = timeline(conversation.id).filter { $0.sender.id == me.id && $0.delivery == .sent }
        var marks: [MessageID: [PersonID]] = [:]
        for (reader, time) in reads.sorted(by: { $0.key < $1.key }) {
            if let newest = mine.last(where: { $0.createdAt <= time }) { marks[newest.id, default: []].append(reader) }
        }
        return marks
    }
    /// Everyone whose receipt covers `message`, for "Seen by …".
    func readers(of message: Message) -> [PersonID] {
        presence.readers(in: message.conversationID, upTo: message.createdAt)
    }
}
