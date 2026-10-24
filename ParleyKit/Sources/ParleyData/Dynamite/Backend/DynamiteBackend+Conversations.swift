import Foundation
import ParleyDomain

extension DynamiteBackend {
    public func conversations() async throws -> [Conversation] {
        let (sorted, topics) = try await worldItems()
        sorted.forEach(remember)
        await resolve(sorted.flatMap(DynamiteMapper.memberIDs))
        await resolve(messages: topics.flatMap(\.replies))
        home = topics.compactMap { DynamiteMapper.homeThread($0, selfID: selfID, people: people) }.sorted {
            $0.time > $1.time
        }
        // A thread opened from Home shows this first message: known here, so reactions and edits to it reach the screen.
        for thread in home where heads[Self.topicKey(thread.head.id)] == nil {
            heads[Self.topicKey(thread.head.id)] = thread.head
        }
        return sorted.compactMap { DynamiteMapper.conversation($0, selfID: selfID, people: people) }
    }
    public func homeThreads() -> [HomeThread] { home }
    /// Home's sections, as Google Chat's web client sends them; the topics they bring arrive in the response's field 7.
    /// The section replies only echo their filters (no items, no token). Checked live: the followed threads come back
    /// only when the last section (label "100G", sort 4) is sent with the first or third; neither brings them alone.
    static let homeSections: [Dynamite_WorldSectionRequest] = {
        let unmuted = Dynamite_WorldFilter.with {
            $0.muteState = 1
            $0.excludeLabels = [.with { $0.type = 3 }]
        }  // UNMUTED, not MUTED
        let unread = Dynamite_WorldFilter.with {
            $0.readState = 4
            $0.muteState = 1
            $0.includeLabels = [.with { $0.type = 5 }]
            $0.excludeLabels = [.with { $0.type = 3 }]  // + HAS_UNREAD_MAIN_MESSAGE
        }
        let flagged = Dynamite_WorldFilter.with { $0.flag17 = true }
        let threads = Dynamite_WorldTopicFilter.with {
            $0.labels = [.with { $0.type = 1 }]
            $0.field4 = true
        }
        let unreadThreads = Dynamite_WorldTopicFilter.with {
            $0.field1 = 1
            $0.labels = [.with { $0.type = 1 }, .with { $0.type = 2 }]
            $0.field4 = true
        }
        return [(unmuted, threads), (unread, unreadThreads), (flagged, threads), (flagged, unreadThreads)].map {
            filter, topics in
            .with { section in
                section.pageSize = 30
                section.worldFilter = filter
                section.topicFilter = topics
                section.topicOption = .with {
                    $0.page = .with {
                        $0.field1 = 1
                        $0.field2 = true
                    }
                    $0.flag.field1 = true
                }
                section.sortKey.sort = 1  // SORT_BY_SORT_TIME_DESC
                section.view.view = 1  // HOME
            }
        } + [
            .with { section in
                section.pageSize = 30
                section.topicOption = .with {
                    $0.page = .with {
                        $0.field1 = 1
                        $0.field2 = true
                    }
                    $0.flag.field1 = true
                }
                section.sortKey.sort = 4
                section.constraints.constraints = [
                    .with { constraint in
                        constraint.kind = 3
                        constraint.expression.binary = .with {
                            $0.op = 2
                            $0.left.text = "label"
                            $0.right.text = "100G"
                        }
                    }
                ]
            }
        ]
    }()
    func remember(_ item: Dynamite_WorldItemLite) {
        guard let id = DynamiteID.conversation(item.groupID) else { return }
        let state = item.readState
        latest[id] = state.lastHeadMessageCreateTime > 0 ? state.lastHeadMessageCreateTime : item.sortTimestamp
        notifyLevel[id] = state.notificationSettings.level
        if state.markAsUnreadTimestamp > 0 { markedUnread.insert(id) } else { markedUnread.remove(id) }
        readUpTo[id] = max(readUpTo[id] ?? 0, state.lastReadTime)
    }
    /// Every sidebar item, one per conversation, most recent first, and the topics Home's sections brought.
    func worldItems() async throws -> ([Dynamite_WorldItemLite], [Dynamite_Topic]) {
        // Joined conversations (unfiltered), plus DMs someone started with us that we haven't accepted yet:
        // The mobile app asks for those in their own section, the web lists them in the sidebar.
        let invited = Dynamite_WorldFilter.with {
            $0.membershipState = .memberInvited
            $0.inviteCategory = .regularInvite
            $0.groupType = .dm
        }
        // My sidebar sections come in an entry of their own: asked on the unfiltered section, Google answers with the
        // sections and no conversations. Its own filter (spaces) keeps its paging token apart from the others'.
        let rosterSections = Dynamite_WorldSectionRequest.with {
            $0.pageSize = 1
            $0.fetchRosterSections = true
            $0.worldFilter.groupType = .room
        }
        var sections: [Dynamite_WorldSectionRequest] =
            [
                .with { $0.pageSize = 200 },
                .with {
                    $0.pageSize = 120
                    $0.worldFilter = invited
                },
                rosterSections,
            ] + Self.homeSections
        var items: [Dynamite_WorldItemLite] = []
        var topics: [Dynamite_Topic] = []
        var seen: Set<String> = []
        for page in 0... {
            guard page < 100 else { throw DynamiteError.malformedReply }
            let request = Dynamite_PaginatedWorldRequest.with { request in
                request.worldSectionRequests = sections
                request.fetchFromUserSpaces = true
                request.fetchSnippetsForUnnamedRooms = true
            }
            let response: Dynamite_PaginatedWorldResponse = try await rpc("paginated_world", request)
            items += response.worldItems + response.worldSectionResponses.flatMap(\.worldItems)
            if page == 0 {
                topics = response.shortcutItems.compactMap {
                    if case .topic(let topic)? = $0.item { topic } else { nil }
                }
                self.rosterSections = response.worldSectionResponses.flatMap(\.rosterSections).compactMap {
                    Self.section($0.section)
                }
            }
            // A section's response echoes its filter; that is how its next token finds it. An unmatched token is dropped.
            let more = response.worldSectionResponses.filter { $0.moreItems && !$0.paginationToken.isEmpty }
            // Home's sections never page (no token), and the followed-threads one shares the unfiltered section's empty filter.
            sections = sections.filter { !$0.hasView && !$0.hasConstraints && !$0.fetchRosterSections }.compactMap {
                section in
                more.first { $0.worldFilter == section.worldFilter }.map { next in
                    var section = section
                    section.paginationToken = next.paginationToken
                    return section
                }
            }
            if sections.isEmpty { break }
            guard sections.allSatisfy({ seen.insert($0.paginationToken).inserted }) else {
                throw DynamiteError.malformedReply
            }
        }
        var unique: [ConversationID: Dynamite_WorldItemLite] = [:]
        // Hidden conversations come back too, marked by their hide time (`Conversation.hidden`); Google Chat leaves them off the sidebar.
        for item in items {
            if let id = DynamiteID.conversation(item.groupID), unique[id] == nil { unique[id] = item }
        }
        return (unique.values.sorted { $0.sortTimestamp > $1.sortTimestamp }, topics)
    }

    /// Others compare this time with server create times to show our read receipt,
    /// so it is the newest message's time, never the Mac's clock unless nothing is loaded, and it only moves forward.
    public func markRead(thread: ThreadID, upTo time: Date) async throws {
        let request = try Dynamite_MarkTopicReadstateRequest.with { request in
            request.topicID = try DynamiteID.topicID(of: thread.head, in: DynamiteID.conversation(of: thread))
            request.lastReadTime = Int64((time.timeIntervalSince1970 * 1_000_000).rounded())
        }
        let _: Dynamite_MarkTopicReadstateResponse = try await rpc("mark_topic_readstate", request)
    }
    /// Google Chat's thread mute is following's opposite; the server answers with the THREAD_FOLLOWED label event.
    public func setFollowing(_ following: Bool, for thread: ThreadID) async throws {
        let request = try Dynamite_MarkTopicMuteStateRequest.with { request in
            request.topicID = try DynamiteID.topicID(of: thread.head, in: DynamiteID.conversation(of: thread))
            request.muted = !following
        }
        let _: Dynamite_MarkTopicMuteStateResponse = try await rpc("mark_Topic_mute_state", request)
    }
    public func markRead(_ conversation: ConversationID) async throws {
        let time = max(
            newest[conversation] ?? Int64(Date.now.timeIntervalSince1970 * 1_000_000), readUpTo[conversation] ?? 0)
        readUpTo[conversation] = time
        let request = try Dynamite_MarkGroupReadstateRequest.with { request in
            request.id = try DynamiteID.group(conversation)
            request.lastReadTime = time
        }
        let _: Dynamite_MarkGroupReadstateResponse = try await rpc("mark_group_readstate", request)
        // Google Chat clears a mark-as-unread right after the read time; the read time alone leaves it unread.
        if markedUnread.contains(conversation) {
            try await setUnreadMark(0, conversation)
            markedUnread.remove(conversation)
        }
        continuation.yield(.readStateChanged(conversation, unread: 0))
    }
    /// Just before the newest message, as Google Chat sends it, so that message shows unread.
    public func markUnread(_ conversation: ConversationID) async throws {
        let newest = max(newest[conversation] ?? 0, latest[conversation] ?? 0)
        try await setUnreadMark(
            (newest > 0 ? newest : Int64(Date.now.timeIntervalSince1970 * 1_000_000)) - 1, conversation)
        markedUnread.insert(conversation)
    }
    /// As Google Chat marks it: the message's time − 1 µs, on the conversation, or on its thread for a reply.
    public func markUnread(from message: Message) async throws {
        let time = Int64((message.createdAt.timeIntervalSince1970 * 1_000_000).rounded()) - 1
        guard let thread = message.threadID else {
            try await setUnreadMark(time, message.conversationID)
            markedUnread.insert(message.conversationID)
            return
        }
        let request = try Dynamite_SetTopicUnreadTimestampRequest.with { request in
            request.topicID = try DynamiteID.topicID(of: thread.head, in: message.conversationID)
            request.unreadTimestamp = time
        }
        let _: Dynamite_SetTopicUnreadTimestampResponse = try await rpc("set_topic_unread_timestamp", request)
    }
    private func setUnreadMark(_ time: Int64, _ conversation: ConversationID) async throws {
        let _: Dynamite_SetMarkAsUnreadTimestampResponse = try await rpc(
            "set_mark_as_unread_timestamp",
            try Dynamite_SetMarkAsUnreadTimestampRequest.with { request in
                request.groupID = try DynamiteID.group(conversation)
                request.markAsUnreadTimestamp = time
            })
    }
    public func setSidebarPinned(_ pinned: Bool, for conversation: ConversationID) async throws {
        let _: Dynamite_StarGroupResponse = try await rpc(
            "star_group",
            try Dynamite_StarGroupRequest.with { request in
                request.groupID = try DynamiteID.group(conversation)
                request.starred = pinned
            })
    }
    /// Mute is separate from the notification level, which is resent as the sidebar last reported it.
    public func setMuted(_ muted: Bool, for conversation: ConversationID) async throws {
        let response = try await updateNotifications(
            conversation, level: notifyLevel[conversation] ?? .notifyAlways, muted: muted)
        if response.notificationSettings.hasLevel { notifyLevel[conversation] = response.notificationSettings.level }
    }
    /// The same request as mute, as Google Chat's settings screen sends it: the new level with the mute state unchanged.
    public func setNotificationLevel(_ level: NotificationLevel, muted: Bool, for conversation: ConversationID)
        async throws
    {
        _ = try await updateNotifications(conversation, level: DynamiteMapper.wire(level), muted: muted)
        notifyLevel[conversation] = DynamiteMapper.wire(level)
    }
    private func updateNotifications(
        _ conversation: ConversationID, level: Dynamite_GroupNotificationSettings.Level, muted: Bool
    )
        async throws -> Dynamite_UpdateGroupNotificationSettingsResponse
    {
        try await rpc(
            "update_group_notification_settings",
            try Dynamite_UpdateGroupNotificationSettingsRequest.with { request in
                request.groupID = try DynamiteID.group(conversation)
                request.notificationSettings.level = level
                request.notificationSettings.muteSettings.state = muted ? .muted : .unmuted
            })
    }
    public func setHidden(_ hidden: Bool, for conversation: ConversationID) async throws {
        let _: Dynamite_HideGroupResponse = try await rpc(
            "hide_group",
            try Dynamite_HideGroupRequest.with { request in
                request.groupID = try DynamiteID.group(conversation)
                request.hidden = hidden
            })
    }
    public func sidebarSections() -> [SidebarSection] { rosterSections }
    private static func section(_ proto: Dynamite_RosterSection) -> SidebarSection? {
        guard let kind = SidebarSection.Kind(rawValue: Int(proto.id.type)) else { return nil }
        return SidebarSection(kind: kind, key: proto.id.secondaryKey, name: proto.name, position: Int(proto.sortOrder))
    }
    private static func sectionID(_ section: SidebarSection) -> Dynamite_RosterSectionId {
        .with {
            $0.type = Int32(section.kind.rawValue)
            $0.label = .with {
                $0.type = 4
                $0.value = section.key
            }
            $0.secondaryKey = section.key
        }
    }
    /// `create_roster_section` as web Chat sends it: a placeholder key ("1") that Google replaces with the section's own.
    public func createSection(named name: String, at position: Int) async throws -> SidebarSection {
        let response: Dynamite_CreateRosterSectionResponse = try await rpc(
            "create_roster_section",
            Dynamite_CreateRosterSectionRequest.with { request in
                request.section = .with {
                    $0.id = Self.sectionID(SidebarSection(kind: .custom, key: "1", position: position))
                    $0.sortOrder = Int64(position)
                    $0.name = name
                    $0.contentSort.order = 1
                }
            })
        guard let made = Self.section(response.section), !made.key.isEmpty else { throw DynamiteError.malformedReply }
        return made
    }
    /// `update_roster_section` names the fields it changes by number, as web Chat sends it: 3 the name, 2 the position.
    private func updateSection(_ section: SidebarSection, mask: Int32, _ change: (inout Dynamite_RosterSection) -> Void)
        async throws
    {
        let _: Dynamite_UpdateRosterSectionResponse = try await rpc(
            "update_roster_section",
            Dynamite_UpdateRosterSectionRequest.with { request in
                request.section = .with {
                    $0.id = Self.sectionID(section)
                    change(&$0)
                }
                request.mask.fields = [mask]
            })
    }
    public func renameSection(_ section: SidebarSection, to name: String) async throws {
        try await updateSection(section, mask: 3) { $0.name = name }
    }
    public func moveSection(_ section: SidebarSection, to position: Int) async throws {
        try await updateSection(section, mask: 2) { $0.sortOrder = Int64(position) }
    }
    public func deleteSection(_ section: SidebarSection) async throws {
        let _: Dynamite_DeleteRosterSectionResponse = try await rpc(
            "delete_roster_section",
            Dynamite_DeleteRosterSectionRequest.with {
                $0.id = Self.sectionID(section)
            })
    }
    /// `remove_group_label` from the section it was in, then `apply_group_label` for the new one, as web Chat moves it.
    public func moveConversation(_ conversation: ConversationID, to section: String?, from previous: String?)
        async throws
    {
        let group = try DynamiteID.group(conversation)
        func label(_ path: String, _ key: String) async throws {
            let _: Dynamite_GroupLabelResponse = try await rpc(
                path,
                Dynamite_GroupLabelRequest.with {
                    $0.label = .with {
                        $0.type = 4
                        $0.value = key
                    }
                    $0.groupID = group
                })
        }
        if let previous, previous != section { try await label("remove_group_label", previous) }
        if let section, section != previous { try await label("apply_group_label", section) }
    }
}
