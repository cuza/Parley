import CoreSpotlight
import ParleyDomain

/// Parley's conversations, and on macOS 27 the people in them, in Spotlight: names only, never
/// message text. Siri with Apple Intelligence finds them there. A conversation result opens it; a person result opens
/// the DM. The first update of a launch, or another account's, rebuilds the index; after that only conversations whose
/// name, members or pin changed are indexed again and only removed ones deleted, never for an unread count. Never for
/// demo or test runs.
@MainActor final class ConversationSpotlight {
    /// What one update asks of the index.
    struct Change: Equatable {
        var clearAll: Bool  // the launch's first update, or another account's
        var conversations: [Conversation]  // to index: all of them when clearing, else the changed and new ones
        var removed: [ConversationID]  // left, hidden or gone since the last update
        var prioritized: Set<ConversationID>  // the ones Shortcuts suggests, pinned then recent: ranked higher
        var all: [Conversation]  // every conversation shown, for the people in them
    }
    private let index: (Change, PersonID) async -> Void
    private var indexed: [ConversationID: String]?
    private var indexedMe: PersonID?
    init(index: @escaping (Change, PersonID) async -> Void = ConversationSpotlight.apply) { self.index = index }
    func update(_ conversations: [Conversation], me: PersonID) async {
        let shown = conversations.filter { $0.hidden == nil }
        // ponytail: recent activity isn't in the signature (it would re-index on every message), so a conversation's rank
        // follows its pin at once and its recency from the next launch's rebuild.
        let signatures = Dictionary(
            shown.map { room in
                (
                    room.id,
                    ([room.name, room.pinned ? "pinned" : ""] + room.members.map { "\($0.id)=\($0.name)" }).joined(
                        separator: "\u{1F}")
                )
            }, uniquingKeysWith: { first, _ in first })
        let clearAll = indexed == nil || indexedMe != me
        let changed = clearAll ? shown : shown.filter { indexed?[$0.id] != signatures[$0.id] }
        let removed = clearAll ? [] : (indexed ?? [:]).keys.filter { signatures[$0] == nil }.sorted()
        guard clearAll || !changed.isEmpty || !removed.isEmpty else { return }
        indexed = signatures
        indexedMe = me
        await index(
            Change(
                clearAll: clearAll, conversations: changed, removed: removed,
                prioritized: Set(ConversationEntity.suggested(shown).map(\.id)), all: shown), me)
    }
    /// Every conversation, after clearing: Spotlight lost its index, or asked for all of it again.
    static func rebuild(_ conversations: [Conversation], me: PersonID) async {
        let shown = conversations.filter { $0.hidden == nil }
        await apply(
            Change(
                clearAll: true, conversations: shown, removed: [],
                prioritized: Set(ConversationEntity.suggested(shown).map(\.id)), all: shown), me: me)
    }
    static func apply(_ change: Change, me: PersonID) async {
        let index = CSSearchableIndex.default()
        if change.clearAll {
            // The default index, as Apple's messaging sample uses: Siri's contact lookup reads it. The named index of
            // earlier builds is emptied so its items don't show twice. A cleared index also drops another account's.
            try? await CSSearchableIndex(name: "conversations").deleteAllSearchableItems()
            try? await index.deleteAllSearchableItems()
        }
        let first = change.conversations.filter { change.prioritized.contains($0.id) }
        let rest = change.conversations.filter { !change.prioritized.contains($0.id) }
        if #available(macOS 27, *) {
            // Siri's messaging templates resolve people and conversations through these.
            if !change.removed.isEmpty {
                try? await index.deleteAppEntities(
                    identifiedBy: change.removed.map(\.rawValue), ofType: SiriConversation.self)
                try? await index.deleteAppEntities(
                    identifiedBy: change.removed.map(\.rawValue), ofType: SiriPerson.self)  // as recipients
            }
            try? await index.indexAppEntities(first.map { SiriConversation($0, me: me) }, priority: 1)
            try? await index.indexAppEntities(rest.map { SiriConversation($0, me: me) })
            // ponytail: everyone known again on each change, and someone who left every conversation stays until the next
            // launch's rebuild; per-person diffing if the people list grows large.
            try? await index.indexAppEntities(
                PersonEntity.known(in: change.all, me: me).map(SiriPerson.init)
                    + SiriPerson.recipients(change.conversations))
        } else {
            if !change.removed.isEmpty {
                try? await index.deleteAppEntities(
                    identifiedBy: change.removed.map(\.rawValue), ofType: ConversationEntity.self)
            }
            try? await index.indexAppEntities(first.map(ConversationEntity.init), priority: 1)
            try? await index.indexAppEntities(rest.map(ConversationEntity.init))
        }
    }
}
