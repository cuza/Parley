import CoreSpotlight

/// Parley's conversations, and on macOS 27 the people in them, in Spotlight: names only, never
/// message text. Siri with Apple Intelligence finds them there. A conversation result opens it; a person result opens
/// the DM. The index is rebuilt only when a name or the members change, not for an unread count, and never for demo or
/// test runs.
@MainActor final class ConversationSpotlight {
    private let index: ([Conversation], PersonID) async -> Void
    private var indexed: [String]?
    init(index: @escaping ([Conversation], PersonID) async -> Void = ConversationSpotlight.replace) { self.index = index }
    func update(_ conversations: [Conversation], me: PersonID) async {
        let shown = conversations.filter { $0.hidden == nil }
        let signature = shown.map { ([$0.id, $0.name] + $0.members.map { "\($0.id)=\($0.name)" }).joined(separator: "\u{1F}") }
        guard signature != indexed else { return }
        indexed = signature
        await index(shown, me)
    }
    /// The whole set each time, after clearing the last: a renamed or removed conversation, or another account's, never stays.
    static func replace(_ conversations: [Conversation], me: PersonID) async {
        // The default index, as Apple's messaging sample uses: Siri's contact lookup reads it. The named index of earlier
        // builds is emptied so its items don't show twice.
        try? await CSSearchableIndex(name: "conversations").deleteAllSearchableItems()
        let index = CSSearchableIndex.default()
        try? await index.deleteAllSearchableItems()
        if #available(macOS 27, *) {
            // Siri's messaging templates resolve people and conversations through these.
            try? await index.indexAppEntities(conversations.map { SiriConversation($0, me: me) })
            try? await index.indexAppEntities(PersonEntity.known(in: conversations, me: me).map(SiriPerson.init) + SiriPerson.recipients(conversations))
        } else {
            try? await index.indexAppEntities(conversations.map(ConversationEntity.init))
        }
    }
}
