import Foundation

public struct MessageDraft: Sendable {
    public var text: String
    public var localID: String
    public var formatting: [TextStyleRange] = []
    public var uploads: [Attachment] = []  // files already uploaded with `ChatBackend.upload` (each has an `uploadToken`)
    public var quoting: QuotedMessage?  // a quote reply: the quoted message, with its `id` and `lastUpdateMicros`
    public var serverDraftID: String?  // the server draft this message was, which the server drops on send
    public var outsiders: [PersonID: Outsider] = [:]  // mentioned people who aren't members; see `ChatStore.outsiders`
    public init(
        text: String, localID: String, formatting: [TextStyleRange] = [], uploads: [Attachment] = [],
        quoting: QuotedMessage? = nil,
        serverDraftID: String? = nil, outsiders: [PersonID: Outsider] = [:]
    ) {
        self.text = text
        self.localID = localID
        self.formatting = formatting
        self.uploads = uploads
        self.quoting = quoting
        self.serverDraftID = serverDraftID
        self.outsiders = outsiders
    }
    /// How a mention of someone outside the conversation goes, as Google Chat sends it: an invitation that adds them, or
    /// a reference that only names them.
    public enum Outsider: Sendable { case invite, reference }
}
/// A composer's draft as Google Chat keeps it on the server, so it follows the user between devices.
public struct ServerDraft: Hashable, Codable, Sendable {
    public var id = ""  // empty until first saved; the backend names it then
    public var conversationID: ConversationID
    public var threadID: ThreadID?  // a thread's reply box has a draft of its own
    public var text: String
    public var formatting: [TextStyleRange] = []
    public var updatedAt: Date = .now  // the server's last update time
    public var schedule: Schedule?  // a scheduled message: Google sends it at this time; nil for a composer's draft
    public init(
        id: String = "", conversationID: ConversationID, threadID: ThreadID? = nil, text: String,
        formatting: [TextStyleRange] = [],
        updatedAt: Date = .now, schedule: Schedule? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.threadID = threadID
        self.text = text
        self.formatting = formatting
        self.updatedAt = updatedAt
        self.schedule = schedule
    }
    public struct Schedule: Hashable, Codable, Sendable {
        public var at: Date
        public var failed = false  // Google tried at that time and couldn't send it
        public init(at: Date, failed: Bool = false) {
            self.at = at
            self.failed = failed
        }
    }
}
