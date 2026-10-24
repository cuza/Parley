import Foundation
import ParleyDomain
import SwiftProtobuf

extension DynamiteBackend {
    /// Applies one pushed event. Internal so tests can drive it without a channel.
    func handle(_ response: Dynamite_StreamEventsResponse) async { await apply(response.event) }

    /// `live: false` for events replayed by a catch-up, which update state but announce nothing.
    func apply(_ event: Dynamite_Event, live: Bool = true) async {
        // Events carry a user or a group revision (a oneof); both are µs timestamps of the last event seen.
        userRevision = max(userRevision, event.userRevision.timestamp, event.groupRevision.timestamp)
        for body in event.bodies {
            switch body.eventType {
            case .sessionReady:
                continuation.yield(.connectionChanged(.connected))
                if readyBefore { await catchUp() }  // the first ready follows a fresh load; later ones follow a gap
                readyBefore = true
            case .messagePosted, .messageUpdated, .topicUpdated, .messageDeleted:
                await applyMessage(event, body, live: live)
            case .messageReacted, .batchReactionsUpdated:
                applyReaction(event, body, live: live)
            case .groupViewed, .topicViewed, .markAsUnread, .markTopicAsUnreadUpdated, .readReceiptChanged,
                .groupUnreadSubscribedTopicCountUpdated, .topicLabelApplied, .topicLabelRemoved:
                applyReadState(event, body)
            case .groupUpdated, .membershipChanged, .groupDeleted, .groupNotificationSettingsUpdated, .groupHideChanged,
                .groupLabelApplied, .groupLabelRemoved, .rosterSectionCreated, .rosterSectionDeleted,
                .rosterSectionUpdated,
                .groupDefaultSortOrderUpdated, .clearHistory, .worldRefreshed, .blockStateChanged:
                await applyConversation(event, body)
            case .unsentMessageCreated, .unsentMessageUpdated, .unsentMessageDeleted:
                applyDraft(body)
            case .typingStateChanged, .activityIndicatorChanged, .userStatusUpdatedEvent, .userRecurringDndUpdatedEvent:
                applyPresence(event, body)
            // Known and not needed: a new topic (its head's MESSAGE_POSTED brings the message), counts for Google Chat's mobile
            // Threads panel and per-thread badges (Home's threads follow TOPIC_VIEWED), sort strings for Google's own lists, thread
            // mute (Parley follows the THREAD_FOLLOWED label), empty signals, a mark-section-read job's progress, and Google's
            // own notify decisions and badge counts (Parley decides its banners and Dock badge itself).
            case .topicCreated, .groupUnreadThreadStateUpdated, .topicMetadataUpdated, .groupReadStateUpdated,
                .stringSortOrderUpdated,
                .topicMuteChanged, .userPresenceSharedUpdatedEvent, .genAiSummaryUpdated, .streamingMessageUpdated,
                .backgroundJobStatusUpdate,
                .webPushNotification, .badgeCountUpdated:
                break
            default:  // numbers only, to see what Google sends that Parley doesn't use yet
                log.info(
                    "event: unhandled type \(body.eventType.rawValue, privacy: .public), fields \(Self.fieldNumbers(body), privacy: .public)"
                )
            }
        }
    }

    /// A message posted, edited, deleted or announced by Google, and an Ask Gemini session's topic.
    private func applyMessage(_ event: Dynamite_Event, _ body: Dynamite_EventBody, live: Bool) async {
        switch body.eventType {
        case .messagePosted, .messageUpdated:
            let proto = body.messagePosted.message
            guard let id = DynamiteID.message(proto.id, in: event.groupID, proto.id.parentID.topicID.groupID) else {
                return
            }
            let conversation = DynamiteID.conversation(of: id)
            if live, conversation.rawValue.hasPrefix("dm/") { await refreshSender(proto.creator.userID.id) }  // DM invites carry placeholders
            await resolve(messages: [proto])
            let placed = place(
                proto, in: conversation, isHead: body.messagePosted.hasIsHead ? body.messagePosted.isHead : nil)
            if placed.isEmpty { deleted(id) }  // tombstone
            placed.forEach { continuation.yield(.messageUpserted($0)) }
        case .topicUpdated:  // an Ask Gemini session's topic, whole: its messages show as MESSAGE_POSTED would show them
            let topic = body.topicUpdated.topic
            guard let conversation = DynamiteID.conversation(topic.id.groupID) ?? DynamiteID.conversation(event.groupID)
            else { return }
            let protos = topic.replies.filter { !$0.id.messageID.isEmpty }.sorted { $0.createTime < $1.createTime }
            log.info("event: topic updated, \(protos.count, privacy: .public) messages")
            await resolve(messages: protos)
            for proto in protos {
                place(proto, in: conversation, isHead: nil).forEach { continuation.yield(.messageUpserted($0)) }
            }
        case .messageDeleted:
            let id = body.messageDeleted.messageID
            guard let message = DynamiteID.message(id, in: event.groupID, id.parentID.topicID.groupID) else { return }
            deleted(message)
        default: break
        }
    }

    /// One person's reaction added or removed, or whole reaction summaries.
    private func applyReaction(_ event: Dynamite_Event, _ body: Dynamite_EventBody, live: Bool) {
        switch body.eventType {
        case .messageReacted:  // one person's reaction added or removed
            let reacted = body.messageReaction
            let id = reacted.messageID
            log.notice("event: one reaction \(reacted.option == .remove ? "removed" : "added", privacy: .public)")
            guard !reacted.reactor.id.isEmpty, let (emoji, custom) = DynamiteMapper.reactionKey(reacted.emoji),
                let message = DynamiteID.message(id, in: event.groupID, id.parentID.topicID.groupID)
            else { return }
            update(message) {
                $0.reactions = Self.toggled(
                    $0.reactions, emoji, custom, by: reacted.reactor.id, present: reacted.option != .remove)
            }
            if live {
                continuation.yield(
                    .reacted(message, emoji: emoji, by: PersonID(reacted.reactor.id), added: reacted.option != .remove))
            }
        case .batchReactionsUpdated:  // whole summaries with partial reactor lists: no reliable who-added-what, so no .reacted
            log.notice("event: reaction summary")
            let id = body.batchReactionsUpdated.messageID
            guard let message = DynamiteID.message(id, in: event.groupID, id.parentID.topicID.groupID) else { return }
            let summaries = body.batchReactionsUpdated.reactionSummaries
            update(message) { [selfID] in
                $0.reactions = DynamiteMapper.reactions(summaries, onto: $0.reactions, selfID: selfID)
            }
        default: break
        }
    }

    /// Read times, unread marks, receipts, unread counts and followed threads, changed here or elsewhere.
    private func applyReadState(_ event: Dynamite_Event, _ body: Dynamite_EventBody) {
        switch body.eventType {
        case .groupViewed:
            log.info("event: conversation viewed")
            if let id = DynamiteID.conversation(body.groupViewed.groupID) {
                readUpTo[id] = max(readUpTo[id] ?? 0, body.groupViewed.viewTime)
                continuation.yield(.conversationViewed(id, at: DynamiteMapper.date(body.groupViewed.viewTime)))
            }
        case .topicViewed:
            log.info("event: thread viewed")
            if let thread = DynamiteID.thread(body.topicViewed.topicID) {
                continuation.yield(.threadViewed(thread, at: DynamiteMapper.date(body.topicViewed.viewTime)))
            }
        case .markAsUnread:
            applyUnreadMark(body.markAsUnread)
        case .markTopicAsUnreadUpdated:
            log.info(
                "event: thread unread mark \(body.markTopicAsUnreadUpdated.markTime > 0 ? "set" : "cleared", privacy: .public)"
            )
            if let thread = DynamiteID.thread(body.markTopicAsUnreadUpdated.topicID) {
                continuation.yield(.threadMarkedUnread(thread, body.markTopicAsUnreadUpdated.markTime > 0))
            }
        case .readReceiptChanged:
            let changed = body.readReceiptChanged
            guard let conversation = DynamiteID.conversation(changed.groupID) ?? DynamiteID.conversation(event.groupID)
            else { return }
            receipts(changed.readReceiptSet, in: conversation)
        case .groupUnreadSubscribedTopicCountUpdated:
            let update = body.groupUnreadSubscribedTopicCountUpdated
            if let id = DynamiteID.conversation(update.groupID) {
                continuation.yield(.unreadThreadsChanged(id, Int(update.unreadSubscribedTopicCount)))
            }
        case .topicLabelApplied, .topicLabelRemoved:
            let label = body.topicLabel
            let topic = label.topicID
            guard label.label.type == .threadFollowed, !topic.topicID.isEmpty,
                let conversation = DynamiteID.conversation(topic.groupID) ?? DynamiteID.conversation(event.groupID)
            else { return }
            continuation.yield(
                .threadFollowChanged(
                    DynamiteID.thread(conversation, topic: topic.topicID),
                    following: body.eventType == .topicLabelApplied))
        default: break
        }
    }

    /// A conversation's unread mark set or cleared, here or elsewhere.
    private func applyUnreadMark(_ mark: Dynamite_MarkAsUnreadEvent) {
        log.info("event: conversation unread mark \(mark.markTime > 0 ? "set" : "cleared", privacy: .public)")
        guard let id = DynamiteID.conversation(mark.groupID) else { return }
        if mark.markTime > 0 {
            markedUnread.insert(id)
            continuation.yield(.conversationMarkedUnread(id))
        } else {
            // Opening it elsewhere clears the mark without moving the read time: read, unless a newer message came.
            // ponytail: newest counts thread replies too, so a reply after the read keeps it unread until a GROUP_VIEWED.
            markedUnread.remove(id)
            let newest = max(newest[id] ?? 0, latest[id] ?? 0)
            if newest > 0, (readUpTo[id] ?? 0) >= newest { continuation.yield(.readStateChanged(id, unread: 0)) }
        }
    }

    /// Conversations and the sidebar: created, changed, hidden, sorted, cleared, moved between sections or blocked.
    private func applyConversation(_ event: Dynamite_Event, _ body: Dynamite_EventBody) async {
        switch body.eventType {
        case .groupUpdated, .membershipChanged, .groupDeleted, .groupNotificationSettingsUpdated:
            await conversationChanged(event, body)
        case .groupHideChanged:  // hidden or shown again, here or elsewhere: read back, marked as the event says
            await conversationChanged(event, body, hidden: body.groupHideChanged.hidden)
        case .groupLabelApplied, .groupLabelRemoved, .rosterSectionCreated, .rosterSectionDeleted,
            .rosterSectionUpdated:
            reload()  // my sidebar sections changed, here or on another device: read them back with the conversations
        case .groupDefaultSortOrderUpdated:
            if let id = DynamiteID.conversation(body.groupDefaultSortOrderUpdated.groupID),
                body.groupDefaultSortOrderUpdated.defaultSortTime > 0
            {
                continuation.yield(
                    .conversationActivity(
                        id, at: DynamiteMapper.date(body.groupDefaultSortOrderUpdated.defaultSortTime)))
            }
        case .clearHistory:
            log.info("event: history cleared")
            if let id = DynamiteID.conversation(body.historyCleared.groupID), body.historyCleared.clearedUpTo > 0 {
                continuation.yield(.historyCleared(id, upTo: DynamiteMapper.date(body.historyCleared.clearedUpTo)))
            }
        case .worldRefreshed:
            log.info("event: Home refreshed")
            continuation.yield(.homeRefreshed)
        case .blockStateChanged:  // the blocked list and the conversation list both change
            log.info("event: block state changed")
            continuation.yield(.blocksChanged)
            reload()
        default: break
        }
    }

    /// A draft saved or dropped, here or elsewhere.
    private func applyDraft(_ body: Dynamite_EventBody) {
        let unsent = body.unsentMessage.unsentMessage
        log.notice(
            "event: draft \(body.eventType == .unsentMessageCreated ? "created" : body.eventType == .unsentMessageUpdated ? "updated" : "deleted", privacy: .public)"
        )
        if body.eventType == .unsentMessageDeleted {
            if !unsent.id.id.isEmpty { continuation.yield(.draftDeleted(unsent.id.id)) }
        } else if let draft = DynamiteMapper.draft(unsent) {
            keepUneditable(unsent)
            continuation.yield(.draftChanged(draft))
        }
    }

    /// Typing, Ask Gemini at work, statuses and DND schedules.
    private func applyPresence(_ event: Dynamite_Event, _ body: Dynamite_EventBody) {
        switch body.eventType {
        case .typingStateChanged:
            let typing = body.typingStateChanged
            let topic = typing.context.topicID
            guard !typing.userID.id.isEmpty, typing.userID.id != selfID,  // Google Chat drops its own
                let conversation = [typing.context.groupID, topic.groupID, event.groupID].lazy.compactMap(
                    DynamiteID.conversation
                ).first
            else { return }
            let thread = topic.topicID.isEmpty ? nil : DynamiteID.thread(conversation, topic: topic.topicID)
            continuation.yield(
                .typingChanged(conversation, thread, PersonID(typing.userID.id), isTyping: typing.state == .typing))
        case .activityIndicatorChanged:  // Ask Gemini at work: no text means it is thinking
            let activity = body.activityIndicatorChanged
            let topic = activity.context.topicID
            guard !activity.userID.id.isEmpty,
                let conversation = [activity.context.groupID, topic.groupID, event.groupID].lazy.compactMap(
                    DynamiteID.conversation
                ).first
            else { return }
            let thread = topic.topicID.isEmpty ? nil : DynamiteID.thread(conversation, topic: topic.topicID)
            let label = activity.state == 2 ? nil : activity.progress.text.isEmpty ? "Thinking" : activity.progress.text
            continuation.yield(.activityChanged(conversation, thread, PersonID(activity.userID.id), label: label))
        case .userStatusUpdatedEvent:
            let status = body.userStatusUpdated.userStatus
            guard !status.userID.id.isEmpty else { return }
            // Mine changed here or on another device: the whole status comes along.
            if status.userID.id == selfID {
                continuation.yield(.ownStatusChanged(DynamiteMapper.ownStatus(status)))
                return
            }
            continuation.yield(
                .presenceChanged(
                    PersonID(status.userID.id), status.dndSettings.dndState == .dnd ? .doNotDisturb : nil,
                    status: DynamiteMapper.customStatus(status)))
        case .userRecurringDndUpdatedEvent:  // the whole set, as get_recurring_dnd answers it
            continuation.yield(
                .dndSchedulesChanged(
                    Self.schedules(body.recurringDndUpdated.recurringDnd, timeZone: TimeZone.current.identifier)))
        default: break
        }
    }

    /// The top-level field numbers a message carries, known or not: what an unhandled event is made of.
    private static func fieldNumbers(_ message: some SwiftProtobuf.Message) -> [Int] {
        guard let data = try? message.serializedData() else { return [] }
        var reader = WireReader(bytes: [UInt8](data)[...])
        var numbers: [Int] = []
        while let key = reader.varint(), key >> 3 > 0 {
            numbers.append(Int(key >> 3))
            let skipped =
                switch key & 7 {
                case 0: reader.varint() != nil
                case 1: reader.skip(8)
                case 2: reader.varint().map { reader.skip(Int($0)) } ?? false
                case 5: reader.skip(4)
                default: false
                }
            guard skipped else { break }
        }
        return numbers
    }
    /// A conversation created, renamed, joined, left or deleted elsewhere: gone when we
    /// left it or it was deleted; otherwise its sidebar item, from the event when sent, else from a fresh world read.
    /// `hidden`: what a hide event says, over the read state, which may not have caught up.
    private func conversationChanged(_ event: Dynamite_Event, _ body: Dynamite_EventBody, hidden: Bool? = nil) async {
        if body.eventType == .groupDeleted, !body.groupDeleted.groupIds.isEmpty {
            body.groupDeleted.groupIds.compactMap(DynamiteID.conversation).forEach {
                continuation.yield(.conversationRemoved($0))
            }
            return
        }
        let membership = body.membershipChanged.newMembership
        guard
            let id = [
                event.groupID, body.groupUpdated.group.groupID, membership.id.groupID,
                body.groupNotificationSettingsUpdated.groupID,
                body.groupHideChanged.groupID,
            ]
            .lazy.compactMap(DynamiteID.conversation).first
        else { return }
        if body.eventType == .groupDeleted || body.groupUpdated.groupUpdateType == .groupDeleted
            || (membership.id.memberID.userID.id == selfID && membership.membershipState == .memberNotAMember)
        {
            continuation.yield(.conversationRemoved(id))
            return
        }
        let item: Dynamite_WorldItemLite?
        // A rename pushed an item with the new avatar but no name: a nameless item for a space-style id is read again.
        if event.hasWorldItemLite, DynamiteID.conversation(event.worldItemLite.groupID) == id,
            !event.worldItemLite.roomName.isEmpty || event.worldItemLite.groupID.spaceID.spaceID.isEmpty
        {
            item = event.worldItemLite
        } else {
            // ponytail: a whole world read per event; use get_group if busy spaces make this chatty.
            do {
                item = try await worldItems().0.first { DynamiteID.conversation($0.groupID) == id }
            } catch {
                log.error("paginated_world failed: \(String(describing: type(of: error)), privacy: .public)")
                return
            }
        }
        guard let item else {
            continuation.yield(.conversationRemoved(id))
            return
        }
        remember(item)
        await resolve(DynamiteMapper.memberIDs(item))
        if var room = DynamiteMapper.conversation(item, selfID: selfID, people: people) {
            if let hidden { room.hidden = hidden ? room.hidden ?? .now : nil }
            continuation.yield(.conversationUpserted(room))
        }
    }
}
