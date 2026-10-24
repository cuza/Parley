import Foundation
import ParleyDomain
import SwiftProtobuf
import os

/// SwiftProtobuf names a `Message` too: within Data, the name means a chat message, as it did before Data was a module.
public typealias Message = ParleyDomain.Message

/// `ChatBackend` over Dynamite RPCs, with realtime events from Google Chat's Punctual channel.
public actor DynamiteBackend: ChatBackend {
    public nonisolated let events: AsyncStream<ChatEvent>
    let continuation: AsyncStream<ChatEvent>.Continuation
    let authorizer: WebSessionAuthorizer
    let google: GoogleServices  // Google's services beyond Chat's API: Drive suggestions, People
    let contacts: GoogleContacts  // Google Contacts' widget: what a person's card and detailed view show
    private let client: DynamiteClient
    let realtime: Bool
    let log = Logger(subsystem: "dev.cuza.Parley", category: "dynamite")
    var selfID = ""
    var people: [String: Person] = [:]
    private var unresolvable: Set<String> = []  // "<bots>/<id>" the server omitted (deleted, external): not asked again
    private var refreshedSenders: Set<String> = []  // re-read once per session (see refreshSender)
    // A thread's loaded replies, by its head's id: from list_topics pages (≤20 per topic), list_messages pages and pushes.
    var threads: [ThreadID: [Message]] = [:]
    var heads: [String: Message] = [:]  // "<conversation>/<topic>" → thread head
    var memberRoles: [ConversationID: [PersonID: MemberRole]] = [:]  // from the last list_members read
    var oldestSort: [ConversationID: Int64] = [:]
    var reachedStart: Set<ConversationID> = []
    var newestSort: [ConversationID: Int64] = [:]  // a window's newest topic, where newer pages continue
    var threadStart: Set<ThreadID> = []
    var channel: Task<Void, Never>?
    var realtimeChannel: PunctualChannel?
    var watched: Set<ConversationID> = []
    var userRevision: Int64 = 0
    // While the realtime channel is down, events are polled with catch_up_user, as a reconnect replays them.
    var poller: Task<Void, Never>?
    var polled = false  // logs the first round only
    var newest: [ConversationID: Int64] = [:]  // newest server create time seen (µs), for mark-read
    var readUpTo: [ConversationID: Int64] = [:]
    var readyBefore = false
    // From the sidebar read, for the sidebar actions.
    var latest: [ConversationID: Int64] = [:]  // newest message time (µs) the sidebar reported
    var notifyLevel: [ConversationID: Dynamite_GroupNotificationSettings.Level] = [:]
    var markedUnread: Set<ConversationID> = []
    // A loaded message's attachments, chips (annotations not rebuilt from its text) and quote, re-sent on edit so they survive it.
    // ponytail: kept for every loaded message with attachments or a quote, like `threads`; prune with them if memory ever matters.
    var attached: [MessageID: (text: String, annotations: [Dynamite_Annotation], quote: Dynamite_QuotedMessageRef?)] =
        [:]
    var seen: Set<MessageID> = []  // every message loaded here, so an edit knows whether it lacks what it keeps

    /// App Nap must not slow the realtime channel's reconnect and the fallback poll while they run: with every window
    /// closed or hidden, which is how a chat app spends most of its time, a dropped connection would come back late and
    /// notifications with it. System sleep stays allowed. Held from connect to disconnect (`stayAwake`).
    var awake: (any NSObjectProtocol)?
    var home: [HomeThread] = []
    var rosterSections: [SidebarSection] = []  // from the last world read
    var shortcutSpaces: [Shortcut: Dynamite_GroupId] = [:]
    /// What a draft written elsewhere holds that Parley's composer can't edit (a space chip, a link preview), by draft id,
    /// with the text it was laid over: saving again puts it back. Formatting, mentions and custom emoji are rebuilt instead.
    var draftExtras: [String: (text: String, annotations: [Dynamite_Annotation])] = [:]
    let media: URLSession  // signed by the authorizer (`attachmentData`)

    public init(authorizer: WebSessionAuthorizer, realtime: Bool = true, media: URLSession? = nil) {
        self.authorizer = authorizer
        google = GoogleServices(authorizer: authorizer)
        contacts = GoogleContacts(authorizer: authorizer)
        self.realtime = realtime
        self.media =
            media
            ?? URLSession(configuration: Self.mediaConfiguration(), delegate: NoAuthRedirects(), delegateQueue: nil)
        client = DynamiteClient(authorizer: authorizer)
        let stream = AsyncStream<ChatEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    /// Every RPC goes through here so an expired session surfaces as Signed out wherever it happens, and every request
    /// carries the web client's header.
    func rpc<Response: SwiftProtobuf.Message>(_ method: String, _ request: some DynamiteRequest) async throws
        -> Response
    {
        var request = request
        request.requestHeader = DynamiteClient.header
        do {
            return try await client.call(method, request)
        } catch AuthFailure.signInRequired {
            continuation.yield(.connectionChanged(.signedOut))
            throw AuthFailure.signInRequired
        } catch AuthFailure.http(let status) {
            log.error("\(method, privacy: .public) returned HTTP \(status, privacy: .public)")
            throw AuthFailure.http(status)
        }
    }

    /// Like `rpc`: a lost session surfaces as Signed out.
    func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await authorizer.data(for: request)
        } catch AuthFailure.signInRequired {
            continuation.yield(.connectionChanged(.signedOut))
            throw AuthFailure.signInRequired
        }
    }

    /// Emits the deletion; a deleted reply also lowers its head's reply count.
    func deleted(_ id: MessageID) {
        continuation.yield(.messageDeleted(id))
        attached[id] = nil
        let topic = Self.topicKey(id)
        if heads[topic]?.id == id {
            heads[topic] = nil
            threads[ThreadID(head: id)] = nil
            return
        }  // the thread goes with its first message
        guard var head = heads[topic], let index = threads[ThreadID(head: head.id)]?.firstIndex(where: { $0.id == id })
        else { return }
        threads[ThreadID(head: head.id)]?.remove(at: index)
        head.replyCount = max(0, head.replyCount - 1)
        heads[topic] = head
        continuation.yield(.messageUpserted(head))
    }

    /// The first message seen for a topic is its head; later ones are replies that bump the head's count.
    /// A message the server says is not a head is a reply even when its head was never loaded here.
    func place(_ proto: Dynamite_Message, in conversation: ConversationID, isHead: Bool? = nil) -> [Message] {
        saw([proto], in: conversation)
        guard var message = DynamiteMapper.message(proto, in: conversation, selfID: selfID, people: people) else {
            return []
        }
        let topic = Self.topicKey(message.id)
        if heads[topic] == nil, isHead == false, !proto.id.parentID.topicID.topicID.isEmpty {
            message.threadID = DynamiteID.thread(conversation, topic: proto.id.parentID.topicID.topicID)
            return [message]
        }
        guard var head = heads[topic], head.id != message.id else {
            message.replyCount = heads[topic]?.replyCount ?? 0  // an edited head keeps its count
            heads[topic] = message
            return [message]
        }
        let thread = ThreadID(head: head.id)
        message.threadID = thread
        if let index = threads[thread]?.firstIndex(where: { $0.id == message.id }) {
            threads[thread]?[index] = message
            return [message]
        }
        threads[thread, default: []].append(message)
        head.replyCount += 1
        heads[topic] = head
        return [message, head]
    }

    /// Changes a loaded head or reply and emits it; a message Parley never loaded is left alone.
    /// A thread loaded on its own (opened from Home) holds its replies without its head: its id is the topic's.
    func update(_ id: MessageID, _ change: (inout Message) -> Void) {
        let topic = Self.topicKey(id)
        let thread =
            heads[topic].map { ThreadID(head: $0.id) }
            ?? ThreadID(topic + "/" + (topic.split(separator: "/").last ?? ""))
        if var head = heads[topic], head.id == id {
            change(&head)
            heads[topic] = head
            continuation.yield(.messageUpserted(head))
        } else if let index = threads[thread]?.firstIndex(where: { $0.id == id }), var reply = threads[thread]?[index] {
            change(&reply)
            threads[thread]?[index] = reply
            continuation.yield(.messageUpserted(reply))
        }
    }

    /// A reply's thread head when Parley never loaded it: a head message's id equals its topic id.
    func unloadedThread(of proto: Dynamite_Message, in conversation: ConversationID) -> ThreadID? {
        let topic = proto.id.parentID.topicID.topicID
        guard !topic.isEmpty, proto.id.messageID != topic, heads["\(conversation.rawValue)/\(topic)"] == nil else {
            return nil
        }
        return DynamiteID.thread(conversation, topic: topic)
    }

    func saw(_ protos: some Sequence<Dynamite_Message>, in conversation: ConversationID) {
        if let time = protos.map(\.createTime).max(), time > newest[conversation] ?? 0 { newest[conversation] = time }
        for proto in protos where !proto.id.messageID.isEmpty {
            let id = DynamiteID.message(
                conversation, topic: proto.id.parentID.topicID.topicID, message: proto.id.messageID)
            seen.insert(id)
            let kept = proto.annotations.filter(Self.uneditable)  // formatting, mentions and custom emoji are rebuilt from the edited text
            let quoted = proto.quotedMessageMetadata
            let quote =
                proto.hasQuotedMessageMetadata
                ? Dynamite_QuotedMessageRef.with {
                    $0.messageID = quoted.messageID
                    $0.lastUpdateTime = quoted.lastUpdateTimeWhenQuoted
                    $0.quoteType = quoted.quoteType == .forward ? .forward : .quoteReply
                } : nil
            attached[id] = kept.isEmpty && quote == nil || proto.deleteTime != 0 ? nil : (proto.textBody, kept, quote)
        }
    }

    static func topicKey(_ id: MessageID) -> String {
        String(id.rawValue[..<(id.rawValue.lastIndex(of: "/") ?? id.rawValue.endIndex)])
    }

    /// Readers and how far each has read; ours is left out, since only others' receipts are shown.
    func receipts(_ set: Dynamite_ReadReceiptSet, in conversation: ConversationID) {
        let reads = set.readReceipts.filter { !$0.user.userID.id.isEmpty && $0.user.userID.id != selfID }
            .map { (PersonID($0.user.userID.id), DynamiteMapper.date($0.lastReadTimestampMicros)) }
        continuation.yield(
            .readReceiptsChanged(
                conversation, Dictionary(reads, uniquingKeysWith: max), enabled: set.hasEnabled ? set.enabled : nil))
    }

    /// Everyone the messages name, then (in a call of their own, as bots) the apps that posted for someone.
    func resolve(messages: [Dynamite_Message]) async {
        await resolve(messages.flatMap(DynamiteMapper.userIDs))
        await resolve(messages.flatMap { DynamiteMapper.appIDs($0) + DynamiteMapper.cardAppIDs($0) }, bots: true)
    }
    /// Google names someone with a placeholder until they accept a DM: the first live message from each sender re-reads
    /// their profile, and a changed name or photo reloads the conversations that show it.
    func refreshSender(_ id: String) async {
        guard id != selfID, let before = people[id], refreshedSenders.insert(id).inserted else { return }
        people[id] = nil
        await resolve([id])
        guard let after = people[id] else {
            people[id] = before
            return
        }
        if after.name != before.name || after.avatarURL != before.avatarURL { continuation.yield(.resync) }
    }
    // ponytail: one get_members call per batch, no chunking; chunk if large accounts hit a server cap.
    /// Best effort: a failed lookup leaves names as "Unknown" rather than failing the caller.
    func resolve(_ ids: some Sequence<String>, bots: Bool = false) async {
        let missing = Set(ids).subtracting(people.keys).filter {
            !$0.isEmpty && !unresolvable.contains("\(bots)/\($0)")
        }
        guard !missing.isEmpty else { return }
        let request = Dynamite_GetMembersRequest.with { request in
            request.membershipIds = missing.sorted().map { id in
                .with {
                    $0.memberID.userID.id = id
                    if bots { $0.memberID.userID.type = .bot }
                }
            }
        }
        do {
            let response: Dynamite_GetMembersResponse = try await rpc("get_members", request)
            for profile in response.memberProfiles where !profile.member.user.userID.id.isEmpty {
                people[profile.member.user.userID.id] = DynamiteMapper.person(profile.member.user)
            }
            unresolvable.formUnion(missing.subtracting(people.keys).map { "\(bots)/\($0)" })
        } catch {
            log.error("get_members failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
