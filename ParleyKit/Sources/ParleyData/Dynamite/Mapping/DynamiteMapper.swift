import Foundation
import ParleyDomain

enum DynamiteMapper {
    /// Google Chat derives "unread" from read times; there is no per-group count.
    static func unread(_ state: Dynamite_GroupReadState) -> Int {
        if state.unreadMessageCount > 0 { return Int(state.unreadMessageCount) }
        let unread = state.lastHeadMessageCreateTime > state.lastReadTime || state.markAsUnreadTimestamp > 0
        return unread ? max(Int(state.unreadSubscribedTopicCount), 1) : 0
    }
    static func date(_ micros: Int64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }
    /// A custom status as shown: its emoji, then its text; nil when there is neither.
    static func customStatus(_ status: Dynamite_UserStatus) -> String? {
        let text = [status.customStatus.emoji.unicode, status.customStatus.statusText].filter { !$0.isEmpty }.joined(
            separator: " ")
        return text.nilIfEmpty
    }
    /// My status: DND while its state says so, else away when presence is not shared. Expiries are µs.
    static func ownStatus(_ status: Dynamite_UserStatus) -> OwnStatus {
        let dnd = status.dndSettings
        let availability: OwnStatus.Availability =
            dnd.dndState == .dnd
            ? .doNotDisturb(until: date(dnd.dndExpiryTimeUsec))
            : status.hasPresenceShared && !status.presenceShared ? .away : .automatic
        let custom = status.customStatus
        let set = status.hasCustomStatus && !(custom.statusText.isEmpty && custom.emoji.unicode.isEmpty)
        return OwnStatus(
            availability: availability,
            custom: set
                ? CustomStatus(
                    text: custom.statusText, emoji: custom.emoji.unicode,
                    expires: custom.stateExpiryTimestampUsec > 0 ? date(custom.stateExpiryTimestampUsec) : nil) : nil)
    }
    /// Hosts whose image links show as the image itself when Google sent no picture for them: GIF services and Google's.
    static func inlinesImages(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return ["klipy.com", "giphy.com", "tenor.com", "googleusercontent.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
    /// Avatar and preview image URLs may be scheme-relative (`//lh3…`). Only https is loaded.
    static func imageURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw), url.scheme == "https",
            url.host() != nil
        else { return nil }
        return url
    }
    /// A personal account or a Workspace customer's, nil when not stated.
    static func organization(_ info: Dynamite_OrganizationInfo) -> Organization? {
        switch info.kind {
        case .consumer: .consumer
        case .customer(let customer):
            customer.customerID.customerID.isEmpty ? nil : .customer(customer.customerID.customerID)
        case nil: nil
        }
    }
    static func person(_ user: Dynamite_User) -> Person {
        Person(
            id: PersonID(user.userID.id), name: user.name.isEmpty ? "Unknown" : user.name,
            avatarURL: imageURL(user.avatarURL),
            email: user.email.nilIfEmpty, organization: organization(user.organization))
    }
    /// A directory entry; its member count adds up the joined people (member type 1), as Google Chat counts them.
    static func space(_ entry: Dynamite_SpaceDirectoryEntry) -> SpaceListing? {
        guard let id = DynamiteID.conversation(entry.groupID) else { return nil }
        let people = entry.memberCounts.counts.filter { $0.membershipState == .memberJoined && $0.memberType == 1 }
        return SpaceListing(
            id: id, name: entry.name.isEmpty ? "Unnamed space" : entry.name,
            emoji: entry.avatarInfo.emoji.unicode.nilIfEmpty,
            avatarURL: imageURL(entry.avatarURL),
            memberCount: people.isEmpty ? nil : people.reduce(0) { $0 + Int($1.count) },
            joined: entry.membershipState == .memberJoined, invited: entry.membershipState == .memberInvited)
    }

    /// Oldest message is the thread head; the rest are its replies.
    static func topic(
        _ proto: Dynamite_Topic, in conversation: ConversationID, selfID: String, people: [String: Person]
    ) -> [Message] {
        let all = proto.replies.sorted { $0.createTime < $1.createTime }
            .compactMap { message($0, in: conversation, selfID: selfID, people: people) }
        guard var head = all.first else { return [] }
        // Google Chat: messages = max(summary total + 1, message count, replies held); the page holds only the newest replies.
        let state = proto.topicReadState
        head.replyCount = max(all.count - 1, Int(state.replySummary.totalReplyCount), Int(state.messageCount) - 1)
        head.following = state.topicLabelID.contains { $0.type == .threadFollowed }
        return [head]
            + all.dropFirst().map {
                var reply = $0
                reply.threadID = ThreadID(head: head.id)
                return reply
            }
    }

    /// A Home thread row from a topic Google Chat sends with the conversation list (its first message and newest reply).
    /// A topic without a reply (a starred message comes back as one) is no thread row.
    static func homeThread(_ proto: Dynamite_Topic, selfID: String, people: [String: Person]) -> HomeThread? {
        guard let conversation = DynamiteID.conversation(proto.id.groupID) else { return nil }
        let messages = topic(proto, in: conversation, selfID: selfID, people: people)
        guard messages.count > 1, let head = messages.first, let latest = messages.last else { return nil }
        let read = proto.topicReadState.lastReadTime
        // As Google Chat: a thread marked unread stays unread until it's read again.
        let unread =
            proto.topicReadState.markAsUnreadTime > 0
            || proto.replies.contains { $0.createTime > read && $0.creator.userID.id != selfID && $0.deleteTime == 0 }
        return HomeThread(
            id: ThreadID(head: head.id), conversationID: conversation, head: head, latest: latest, unread: unread,
            time: proto.sortTime > 0 ? date(proto.sortTime) : latest.createdAt)
    }

    static func memberIDs(_ item: Dynamite_WorldItemLite) -> [String] {
        Set((item.dmMembers.members + item.nameUsers.users).map(\.id).filter { !$0.isEmpty }).sorted()
    }

    static func conversation(_ item: Dynamite_WorldItemLite, selfID: String, people: [String: Person]) -> Conversation?
    {
        guard let id = DynamiteID.conversation(item.groupID) else { return nil }
        let members = memberIDs(item).map { people[$0] ?? Person(id: PersonID($0), name: "Unknown") }
        let others = members.filter { $0.id.rawValue != selfID }
        let isDM = !item.groupID.dmID.dmID.isEmpty
        let groupDM = item.attributes.contains { $0.value == "GROUP_DM" }  // stays a group DM when someone names it
        let kind: ConversationKind =
            isDM ? (others.count <= 1 ? .direct : .group) : (groupDM || item.roomName.isEmpty ? .group : .space)
        let name =
            !item.roomName.isEmpty
            ? item.roomName
            : !item.nameUsers.groupName.isEmpty
                ? item.nameUsers.groupName
                : others.isEmpty ? "Unnamed conversation" : others.map(\.name).sorted().joined(separator: ", ")
        // A space's emoji comes before its image; a 1:1 DM shows the other person's photo.
        return Conversation(
            id: id, name: name, kind: kind, members: members,
            unread: unread(item.readState),
            unreadThreads: item.readState.unreadSubscribedTopicCount > 0
                ? Int(item.readState.unreadSubscribedTopicCount) : nil,
            pinned: item.readState.starred,
            muted: item.readState.notificationSettings.muteSettings.state == .muted,
            emoji: item.avatarInfo.emoji.unicode.nilIfEmpty,
            avatarURL: imageURL(item.avatarURL) ?? (kind == .direct ? others.first?.avatarURL : nil),
            description: item.groupLite.spaceDetails.description_p.nilIfEmpty,
            guidelines: item.groupLite.spaceDetails.guidelines.nilIfEmpty,
            historyOff: item.groupLite.hasRetention ? item.groupLite.retention.state == .ephemeralOneDay : nil,
            section: item.readState.labels.first { $0.type == 4 && !$0.value.isEmpty }?.value,
            notificationLevel: item.readState.notificationSettings.hasLevel
                ? level(item.readState.notificationSettings.level) : nil,
            app: kind != .direct
                ? nil
                : item.groupType == 11
                    ? .gemini
                    : item.groupType == 2 || item.dmMembers.members.contains { $0.type == .bot } ? .bot : nil,
            activity: item.sortTimestamp > 0 ? date(item.sortTimestamp) : nil,
            hidden: item.readState.hideTimestamp > 0 ? date(item.readState.hideTimestamp) : nil,
            external: item.hasGuestAccess ? item.guestAccess.state == .guestAccessEnabled : nil)
    }

    static func level(_ wire: Dynamite_GroupNotificationSettings.Level) -> NotificationLevel {
        switch wire {
        case .notifyAlways: .always
        case .notifyForMainConversationsWithAutofollow: .all
        case .notifyForMainConversations: .main
        case .notifyLessWithNewThreads: .forYouAndNewThreads
        case .notifyLess: .forYou
        case .notifyNever: .off
        }
    }
    static func wire(_ level: NotificationLevel) -> Dynamite_GroupNotificationSettings.Level {
        switch level {
        case .always: .notifyAlways
        case .all: .notifyForMainConversationsWithAutofollow
        case .main: .notifyForMainConversations
        case .forYouAndNewThreads: .notifyLessWithNewThreads
        case .forYou: .notifyLess
        case .off: .notifyNever
        }
    }
}

// Server drafts and scheduled messages: Google Chat's unsent messages of type DRAFT and SCHEDULED.
extension DynamiteMapper {
    /// A draft or scheduled message as Google Chat lists or pushes it; one naming no conversation, or scheduled with no
    /// time, is none.
    static func draft(_ proto: Dynamite_UnsentMessage) -> ServerDraft? {
        guard !proto.id.id.isEmpty, let conversation = DynamiteID.conversation(proto.id.groupID) else { return nil }
        let schedule = time(proto.scheduledSend.sendTime).map {
            ServerDraft.Schedule(at: $0, failed: proto.scheduledSend.state == .failed)
        }
        if proto.type == .scheduled, schedule == nil { return nil }
        let rich = richText(proto.textBody, proto.annotations)
        let topic = proto.id.topicID
        return ServerDraft(
            id: proto.id.id, conversationID: conversation,
            threadID: topic.isEmpty ? nil : DynamiteID.thread(conversation, topic: topic),
            text: rich.text, formatting: rich.formatting,
            updatedAt: time(proto.updateTime) ?? time(proto.createTime) ?? .now,
            schedule: proto.type == .scheduled ? schedule : nil)
    }
    static func time(_ timestamp: Dynamite_Timestamp) -> Date? {
        timestamp.seconds > 0
            ? Date(timeIntervalSince1970: Double(timestamp.seconds) + Double(timestamp.nanos) / 1e9) : nil
    }
    /// The draft's id as Google Chat names it: the client-chosen id, its conversation, and its thread's topic for a thread draft.
    static func unsentID(_ id: String, conversation: ConversationID, thread: ThreadID?) throws
        -> Dynamite_UnsentMessageId
    {
        try .with {
            $0.id = id
            $0.groupID = try DynamiteID.group(conversation)
            if let thread { $0.topicID = try DynamiteID.topic(of: thread.head) }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
