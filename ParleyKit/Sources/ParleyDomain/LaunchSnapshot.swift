import Foundation

/// What the store keeps between launches, so the window shows the last conversations and drafts before Google answers.
public struct LaunchSnapshot: Codable, Sendable {
    public var accountID: PersonID?  // whose cache this is; another account's is discarded when that account connects
    public var conversations: [Conversation] = []
    public var messages: [Message] = []
    public var selectedID: ConversationID?
    public var drafts: [String: String] = [:]
    public var draftFormatting: [String: [TextStyleRange]] = [:]
    public var draftEdits: [String: Date] = [:]  // drafts changed on this Mac since last saved to Google, and when
    public var serverDrafts: [String: ServerDraft] = [:]  // per draft key, Google's copy as last saved or heard of
    public var homeThreads: [HomeThread] = []
    public var customEmoji: [CustomEmoji] = []  // the organisation's, so the picker has them before this launch reads the list
    public init(
        accountID: PersonID? = nil, conversations: [Conversation] = [], messages: [Message] = [],
        selectedID: ConversationID? = nil,
        drafts: [String: String] = [:], draftFormatting: [String: [TextStyleRange]] = [:],
        draftEdits: [String: Date] = [:],
        serverDrafts: [String: ServerDraft] = [:], homeThreads: [HomeThread] = [], customEmoji: [CustomEmoji] = []
    ) {
        self.accountID = accountID
        self.conversations = conversations
        self.messages = messages
        self.selectedID = selectedID
        self.drafts = drafts
        self.draftFormatting = draftFormatting
        self.draftEdits = draftEdits
        self.serverDrafts = serverDrafts
        self.homeThreads = homeThreads
        self.customEmoji = customEmoji
    }
}
extension LaunchSnapshot {
    /// Caches written before draft formatting existed lack that key. Ones written before server drafts count every draft
    /// as an old local edit, never saved to Google: pushed unless Google has a draft there too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let drafts = try container.decode([String: String].self, forKey: .drafts)
        // A model change loses cached history, which the server has, never drafts, which only this file has.
        self.init(
            accountID: try container.decodeIfPresent(PersonID.self, forKey: .accountID),
            conversations: (try? container.decode([Conversation].self, forKey: .conversations)) ?? [],
            messages: (try? container.decode([Message].self, forKey: .messages)) ?? [],
            selectedID: try container.decodeIfPresent(ConversationID.self, forKey: .selectedID), drafts: drafts,
            // Each draft field on its own: one this build can't read costs that field (formatting, sync state), not the text.
            draftFormatting: (try? container.decodeIfPresent([String: [TextStyleRange]].self, forKey: .draftFormatting))
                ?? [:],
            draftEdits: (try? container.decodeIfPresent([String: Date].self, forKey: .draftEdits))
                ?? drafts.filter { !$0.value.isEmpty }.mapValues { _ in .distantPast },
            serverDrafts: (try? container.decodeIfPresent([String: ServerDraft].self, forKey: .serverDrafts)) ?? [:],
            homeThreads: (try? container.decodeIfPresent([HomeThread].self, forKey: .homeThreads)) ?? [],
            customEmoji: (try? container.decodeIfPresent([CustomEmoji].self, forKey: .customEmoji)) ?? [])
    }
}

/// Where the launch snapshot is kept; the store reads it once at launch and writes it as things change.
public protocol LaunchCaching: Sendable {
    func load() -> LaunchSnapshot
    func save(_ snapshot: LaunchSnapshot) throws
}
