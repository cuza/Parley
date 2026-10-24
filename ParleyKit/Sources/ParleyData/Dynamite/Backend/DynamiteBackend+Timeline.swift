import Foundation
import ParleyDomain

extension DynamiteBackend {
    public func messages(in conversation: ConversationID, thread: ThreadID?, before: Date?) async throws -> MessagePage
    {
        if let thread { return try await threadPage(thread, in: conversation, older: before != nil) }
        let older = before != nil
        if older, reachedStart.contains(conversation) || oldestSort[conversation] == nil {
            return MessagePage(messages: [], hasMore: false)
        }
        var filter: Dynamite_ListTopicsFilter?
        if older, let anchor = oldestSort[conversation] { filter = .with { $0.olderThan = anchor } }  // PAGINATION_BACKWARDS
        let (response, heads) = try await topicsPage(in: conversation, filter: filter, withReceipts: !older)
        let oldest = response.topics.map(\.sortTime).filter { $0 > 0 }.min()
        if older, let anchor = oldestSort[conversation] {
            // Nothing older than the anchor: we're at the start, or the server ignored the anchor. Either way, stop.
            if let oldest, oldest < anchor {
                oldestSort[conversation] = oldest
            } else {
                reachedStart.insert(conversation)
            }
        } else {
            oldestSort[conversation] = oldest  // a fresh most-recent load restarts paging from its own oldest thread
            newestSort[conversation] = nil
        }
        if response.containsFirstTopic {
            reachedStart.insert(conversation)
        } else if !older {
            reachedStart.remove(conversation)
        }
        return MessagePage(messages: heads, hasMore: !reachedStart.contains(conversation))
    }
    /// `list_topics` anchored on the message's topic: the page around it, as web Chat opens an old search result.
    public func messages(around message: MessageID, in conversation: ConversationID) async throws -> MessagePage {
        let around = try DynamiteID.topicID(of: message, in: conversation)
        let (response, heads) = try await topicsPage(
            in: conversation, filter: .with { $0.aroundTopic = around }, withReceipts: true)
        let sorts = response.topics.map(\.sortTime).filter { $0 > 0 }
        oldestSort[conversation] = sorts.min()
        newestSort[conversation] = sorts.max()
        if response.containsFirstTopic { reachedStart.insert(conversation) } else { reachedStart.remove(conversation) }
        return MessagePage(
            messages: heads, hasMore: !reachedStart.contains(conversation), hasNewer: !response.containsLastTopic)
    }
    /// `list_topics` newer than the window's newest topic (PAGINATION_FORWARDS).
    public func newerMessages(in conversation: ConversationID) async throws -> MessagePage {
        guard let anchor = newestSort[conversation] else {
            return MessagePage(messages: [], hasMore: !reachedStart.contains(conversation))
        }
        let (response, heads) = try await topicsPage(
            in: conversation, filter: .with { $0.newerThan = anchor }, withReceipts: false)
        guard let newest = response.topics.map(\.sortTime).max(), newest > anchor else {
            return MessagePage(messages: heads, hasMore: !reachedStart.contains(conversation))  // nothing newer: the window met the present
        }
        newestSort[conversation] = newest
        return MessagePage(
            messages: heads, hasMore: !reachedStart.contains(conversation), hasNewer: !response.containsLastTopic)
    }
    /// `list_topics` with the thread-summary flag, as Google Chat's Active threads asks: Google sends only threads with replies.
    public func threads(in conversation: ConversationID) async throws -> [ThreadSummary] {
        let group = try DynamiteID.group(conversation)
        let response: Dynamite_ListTopicsResponse = try await rpc(
            "list_topics",
            Self.topicsRequest(
                group, order: 1, topics: 40, unreadReplies: 1000, filter: .with { $0.threadSummary = true }))
        await resolve(messages: response.topics.flatMap(\.replies))
        let summaries = response.topics.compactMap { topic -> ThreadSummary? in
            let messages = DynamiteMapper.topic(topic, in: conversation, selfID: selfID, people: people)
            guard let head = messages.first else { return nil }
            threads[ThreadID(head: head.id)] = Array(messages.dropFirst())
            heads[Self.topicKey(head.id)] = head
            let summary = topic.topicReadState.replySummary
            return ThreadSummary(
                head: head, replyCount: Int(summary.totalReplyCount), unreadCount: Int(summary.unreadReplyCount),
                mentionsMe: !summary.unreadAttributes.isEmpty,
                following: topic.topicReadState.topicLabelID.contains { $0.type == .threadFollowed },
                lastReply: DynamiteMapper.date(topic.sortTime))
        }
        // Seen up to the newest thread, as Google Chat marks the list each time it shows it; a failure only leaves the badge.
        if let newest = response.topics.map(\.sortTime).max() {
            let _: Dynamite_MarkGroupReadstateResponse? = try? await rpc(
                "mark_group_readstate",
                Dynamite_MarkGroupReadstateRequest.with {
                    $0.id = group
                    $0.threadSummaryReadTime = newest
                })
        }
        return summaries
    }
    /// One `list_topics` page of a conversation's main timeline: its thread heads, each thread's loaded replies kept.
    private func topicsPage(in conversation: ConversationID, filter: Dynamite_ListTopicsFilter?, withReceipts: Bool)
        async throws -> (Dynamite_ListTopicsResponse, [Message])
    {
        let request = Self.topicsRequest(try DynamiteID.group(conversation), receipts: withReceipts, filter: filter)
        let response: Dynamite_ListTopicsResponse = try await rpc("list_topics", request)
        if response.hasReadReceiptSet { receipts(response.readReceiptSet, in: conversation) }
        saw(response.topics.flatMap(\.replies), in: conversation)
        await resolve(messages: response.topics.flatMap(\.replies))
        let topics = response.topics.map { DynamiteMapper.topic($0, in: conversation, selfID: selfID, people: people) }
            .filter { !$0.isEmpty }
        for topic in topics {
            threads[ThreadID(head: topic[0].id)] = Array(topic.dropFirst())
            heads[Self.topicKey(topic[0].id)] = topic[0]
        }
        return (response, topics.map { $0[0] })
    }
    /// A `list_topics` request as Google Chat sends it. `order` 2 is a timeline's (see the proto), 1 newest reply first.
    /// Google Chat always asks for TOPIC_METADATA: it carries each thread's real reply count. READ_RECEIPTS fills field 6.
    private static func topicsRequest(
        _ group: Dynamite_GroupId, order: Int32 = 2, topics: Int32 = 30, unreadReplies: Int32 = 20,
        receipts: Bool = false, filter: Dynamite_ListTopicsFilter? = nil
    ) -> Dynamite_ListTopicsRequest {
        .with { request in
            request.groupID = group
            request.field11 = order
            request.pageSizeForTopics = topics
            request.fetchOptions = receipts ? [.topicMetadata, .readReceipts] : [.topicMetadata]
            request.pageSizeForUnreadReplies = unreadReplies
            request.pageSizeForReadReplies = 20
            if let filter { request.filter = filter }
        }
    }

    private static let repliesPerPage = 30

    /// A thread's replies, newest page first, then older pages, all via list_messages.
    /// list_topics' replies aren't used here: for unread threads they are the oldest unread ones, not the newest.
    private func threadPage(_ thread: ThreadID, in conversation: ConversationID, older: Bool) async throws
        -> MessagePage
    {
        if older, threadStart.contains(thread) { return MessagePage(messages: [], hasMore: false) }
        let held = older ? threads[thread] ?? [] : []
        let anchor = held.map { Int64(($0.createdAt.timeIntervalSince1970 * 1_000_000).rounded()) }.min()
        let request = try Dynamite_ListMessagesRequest.with { request in
            request.parentID.topicID.topicID = try DynamiteID.topic(of: thread.head)
            request.parentID.topicID.groupID = try DynamiteID.group(conversation)
            request.pageSize = Int32(Self.repliesPerPage)
            request.filter.olderThan = anchor ?? 9_007_199_254_740_991  // 2^53−1: the newest replies (the LATEST anchor)
        }
        let response: Dynamite_ListMessagesResponse = try await rpc("list_messages", request)
        saw(response.messages, in: conversation)
        await resolve(messages: response.messages)
        let known = Set(held.map(\.id))
        let fetched = response.messages
            .compactMap { DynamiteMapper.message($0, in: conversation, selfID: selfID, people: people) }
            .filter { $0.id != thread.head && !known.contains($0.id) }  // the anchor may be inclusive
            .map {
                var reply = $0
                reply.threadID = thread
                return reply
            }
            .sorted { $0.createdAt < $1.createdAt }
        threads[thread] = (fetched + held).sorted { $0.createdAt < $1.createdAt }
        let done = response.containsFirstMessage || fetched.isEmpty || response.messages.count < Self.repliesPerPage
        if done { threadStart.insert(thread) } else { threadStart.remove(thread) }
        return MessagePage(messages: fetched, hasMore: !done)
    }

    public func searchMessages(matching query: String, filters: SearchFilters, cursor: String?) async throws
        -> SearchPage
    {
        // The "said in" conversations: Google refuses a scope without a sort.
        let groups = try filters.saidIn.map(DynamiteID.group)
        let request = Dynamite_SearchMessagesV2Request.with { request in
            request.size = 20
            if let cursor { request.cursor = cursor }
            request.filter = Self.filter(filters, selfID: selfID)  // Google Chat always sends the filter, empty when unfiltered
            if !groups.isEmpty {
                request.filter.scope.conversations = groups.map { group in
                    .with {
                        $0.groupID = group
                        $0.kind = 1
                    }
                }
                request.sort.operator = .relevance
            }
            request.query = query
        }
        let response: Dynamite_SearchMessagesV2Response = try await rpc("search_messages_v2", request)
        let protos = response.results.items.map(\.message)
        await resolve(messages: protos)
        return SearchPage(messages: protos.compactMap(located), cursor: response.cursor.isEmpty ? nil : response.cursor)
    }
    /// The chips in the shapes Google reads them; none of them needs a sort. Dates are in µs: milliseconds fail.
    static func filter(_ filters: SearchFilters, selfID: String) -> Dynamite_SearchFilter {
        .with { filter in
            filter.senders = filters.from.map { person in .with { $0.id = person.id.rawValue } }
            if filters.after != nil || filters.before != nil {
                if let after = filters.after { filter.dates.startUsec = Int64(after.timeIntervalSince1970 * 1_000_000) }
                if let before = filters.before {
                    filter.dates.endUsec = Int64(before.timeIntervalSince1970 * 1_000_000)
                }
            }
            let types: [SearchFilters.Kind: Dynamite_Annotation.TypeEnum] = [
                .file: .driveFile, .document: .driveDoc, .spreadsheet: .driveSheet,
                .presentation: .driveSlide, .video: .video, .image: .image, .pdf: .pdf,
            ]
            filter.has = filters.has.compactMap { types[$0] }.sorted { $0.rawValue < $1.rawValue }.map { type in
                .with { $0.type = type }
            }
            if filters.mentionsMe { filter.mentions = [.with { $0.users = [.with { $0.id = selfID }] }] }
            if filters.has.contains(.link) { filter.hasLink_p = true }
        }
    }
    /// A message from anywhere (search, shortcuts) in its conversation, pointing at its thread when it is a reply.
    private func located(_ proto: Dynamite_Message) -> Message? {
        guard let conversation = DynamiteID.conversation(proto.id.parentID.topicID.groupID),
            var message = DynamiteMapper.message(proto, in: conversation, selfID: selfID, people: people)
        else { return nil }
        if let head = heads[Self.topicKey(message.id)], head.id != message.id {
            message.threadID = ThreadID(head: head.id)
        } else {
            message.threadID = unloadedThread(of: proto, in: conversation)
        }
        return message
    }
    /// `get_chat_board` with the options Google Chat's Board panel sends; its pinned messages, as they are now.
    public func boardMessages(in conversation: ConversationID) async throws -> [Message] {
        let request = try Dynamite_GetChatBoardRequest.with { request in
            request.groupID = try DynamiteID.group(conversation)
            request.options.messages = .with {
                $0.a = 5
                $0.b = 2
                $0.c = true
            }
            request.options.resources = .with {
                $0.a = 3
                $0.b = true
            }
        }
        let response: Dynamite_GetChatBoardResponse = try await rpc("get_chat_board", request)
        await resolve(messages: response.pinned.messages)
        return response.pinned.messages.compactMap(located)
    }
    /// A Mentions or Starred shortcut. Google Chat keeps each as a hidden space ("Shortcut-MENTIONS", "Shortcut-STARRED")
    /// of copies, each naming its original message; `paginated_world` with the shortcut's section returns that space,
    /// and its topics page like any conversation's. `cursor`: the oldest topic's sort time.
    public func shortcut(_ shortcut: Shortcut, cursor: String?) async throws -> SearchPage {
        guard shortcut != .home else { return SearchPage(messages: [], cursor: nil) }  // Home is built from held conversations
        guard shortcut != .drafts else { return SearchPage(messages: [], cursor: nil) }  // drafts come from `drafts()`
        // Personal (non-Workspace) accounts have no shortcut spaces: Google refuses the section, and Google Chat shows the list empty.
        let space: Dynamite_GroupId
        do {
            space = try await shortcutSpace(shortcut)
        } catch AuthFailure.http(403) {
            return SearchPage(messages: [], cursor: nil)
        } catch DynamiteError.notYetSupported {
            return SearchPage(messages: [], cursor: nil)
        }
        let anchor = cursor.flatMap { Int64($0) }
        let request = Self.topicsRequest(space, filter: anchor.map { anchor in .with { $0.olderThan = anchor } })
        let response: Dynamite_ListTopicsResponse = try await rpc("list_topics", request)
        let protos = response.topics.flatMap(\.replies).compactMap { copy -> Dynamite_Message? in
            guard copy.shortcutSource.ref.hasMessageID else { return nil }
            var original = copy
            original.id = copy.shortcutSource.ref.messageID
            return original
        }
        await resolve(messages: protos)
        var seen: Set<MessageID> = []
        let messages = protos.compactMap(located)
            .filter { seen.insert($0.id).inserted }
            .map { message in
                var message = message
                if shortcut == .starred { message.starred = true }
                return message
            }
            .sorted { $0.createdAt > $1.createdAt }
        let oldest = response.topics.map(\.sortTime).filter { $0 > 0 }.min()
        return SearchPage(messages: messages, cursor: response.containsFirstTopic ? nil : oldest.map(String.init))
    }
    private func shortcutSpace(_ shortcut: Shortcut) async throws -> Dynamite_GroupId {
        if let space = shortcutSpaces[shortcut] { return space }
        let kind: Dynamite_WorldFilter.ShortcutType = shortcut == .mentions ? .mentions : .starred
        let request = Dynamite_PaginatedWorldRequest.with { request in
            request.worldSectionRequests = [
                .with { section in
                    section.pageSize = 30
                    section.worldFilter = .with {
                        $0.groupType = .room
                        $0.shortcutTypes = [kind]
                    }
                    section.field7 = 2
                }
            ]
        }
        let response: Dynamite_PaginatedWorldResponse = try await rpc("paginated_world", request)
        guard let space = (response.worldItems + response.worldSectionResponses.flatMap(\.worldItems)).first?.groupID,
            DynamiteID.conversation(space) != nil
        else { throw DynamiteError.notYetSupported("\(shortcut.title)") }
        shortcutSpaces[shortcut] = space
        return space
    }

    /// `list_attachments`: one category's shared items in a conversation, 20 a page, older than `after`.
    public func shared(_ category: SharedCategory, in conversation: ConversationID, after: SharedContent.Item?)
        async throws -> SharedPage
    {
        let pageSize: Int32 = 20
        let request = try Dynamite_ListAttachmentsRequest.with { request in
            request.groupID = try DynamiteID.group(conversation)
            // Sent in their legacy numbers, as Google Chat's clients do.
            let wanted: Dynamite_AttachmentCategory =
                switch category {
                case .media: .mediaLegacy
                case .files: .fileLegacy
                case .links: .link
                }
            request.categories = [wanted]
            if category == .media { request.filter.mediaTypes = [1, 2] }  // images and videos
            request.filter.includeInlineReplies = true
            request.filter.field6 = true
            request.direction = 1  // older than the anchor
            request.pageSize = pageSize
            if let anchor = after?.messageID {
                request.anchor = try DynamiteID.protoMessageID(anchor)
                request.includeAnchor = false
            } else {
                request.includeAnchor = true
            }
        }
        let response: Dynamite_ListAttachmentsResponse = try await rpc("list_attachments", request)
        let items = response.results.flatMap(\.items)
        await resolve(items.map(\.creator.id))
        let shared = items.compactMap { item -> SharedContent.Item? in
            guard let attachment = DynamiteMapper.sharedAttachment(item.annotation) else { return nil }
            let topic = item.messageID.parentID.topicID.topicID
            let message = item.messageID.messageID
            return SharedContent.Item(
                attachment: attachment, date: DynamiteMapper.date(item.createTime),
                sender: people[item.creator.id]?.name ?? "",
                messageID: topic.isEmpty || message.isEmpty
                    ? nil : DynamiteID.message(conversation, topic: topic, message: message))
        }
        return SharedPage(items: shared, hasMore: items.count >= pageSize && shared.last?.messageID != nil)
    }
}
