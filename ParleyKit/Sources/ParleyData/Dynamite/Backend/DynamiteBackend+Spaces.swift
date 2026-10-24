import Foundation
import ParleyDomain

extension DynamiteBackend {
    /// Removes my own membership, as Google Chat leaves a space.
    public func leave(_ conversation: ConversationID) async throws {
        guard try await removeMembership(PersonID(selfID), conversation) else { throw DynamiteError.leaveRefused }
    }
    public func removeMember(_ person: PersonID, from conversation: ConversationID) async throws {
        guard try await removeMembership(person, conversation) else { throw DynamiteError.removeRefused }
    }
    /// `remove_memberships` with one member; false when the server refused.
    private func removeMembership(_ person: PersonID, _ conversation: ConversationID) async throws -> Bool {
        let response: Dynamite_RemoveMembershipsResponse = try await rpc(
            "remove_memberships",
            try Dynamite_RemoveMembershipsRequest.with { request in
                request.memberIds = [.with { $0.userID.id = person.rawValue }]
                request.groupID = try DynamiteID.group(conversation)
            })
        return !response.results.contains(where: \.hasFailureReason)
    }
    /// `create_membership` with invitees, as web Chat's "Add people" sends it (a space invites them).
    public func addMembers(_ people: [PersonID], to conversation: ConversationID) async throws {
        let response: Dynamite_CreateMembershipResponse = try await rpc(
            "create_membership",
            try Dynamite_CreateMembershipRequest.with { request in
                request.groupID = try DynamiteID.group(conversation)
                request.invitees = people.map { id in
                    .with {
                        $0.invitee = invitee(id)
                        $0.field4 = 1
                        $0.field5 = 1
                    }
                }
            })
        if response.results.contains(where: \.hasFailureReason) { throw DynamiteError.addRefused }
    }
    /// `update_group` with only the changed fields named in its mask, as web Chat's space details save.
    public func updateProfile(_ conversation: ConversationID, name: String?, emoji: String?) async throws {
        let _: Dynamite_UpdateGroupResponse = try await rpc(
            "update_group",
            try Dynamite_UpdateGroupRequest.with { request in
                if let name {
                    request.name = name
                    request.updateMasks.append(.name)
                }
                if let emoji {
                    request.avatarInfo.emoji.unicode = emoji
                    request.updateMasks.append(.avatar)
                }
                request.groupID = try DynamiteID.group(conversation)
            })
    }
    public func updateDetails(_ conversation: ConversationID, description: String, guidelines: String) async throws {
        let _: Dynamite_UpdateGroupResponse = try await rpc(
            "update_group",
            try Dynamite_UpdateGroupRequest.with { request in
                request.groupDetails = .with {
                    $0.description_p = description
                    $0.guidelines = guidelines
                }
                request.updateMasks = [.details]
                request.groupID = try DynamiteID.group(conversation)
            })
    }
    /// `update_membership_role`, one change, as Google Chat's member list sends it.
    public func setRole(_ role: MemberRole, for person: PersonID, in conversation: ConversationID) async throws {
        let group = try DynamiteID.group(conversation)
        let _: Dynamite_UpdateMembershipRoleResponse = try await rpc(
            "update_membership_role",
            Dynamite_UpdateMembershipRoleRequest.with { request in
                request.changes = [
                    .with {
                        $0.role =
                            switch role {
                            case .member: .member
                            case .manager: .manager
                            case .owner: .owner
                            }
                        $0.userID.id = person.rawValue
                        $0.groupID = group
                    }
                ]
            })
        memberRoles[conversation, default: [:]][person] = role
    }
    /// `update_group_retention_settings`, with the id Google Chat gives the system message that announces it.
    public func setHistory(_ on: Bool, for conversation: ConversationID) async throws {
        let _: Dynamite_UpdateGroupRetentionSettingsResponse = try await rpc(
            "update_group_retention_settings",
            try Dynamite_UpdateGroupRetentionSettingsRequest.with { request in
                request.groupID = try DynamiteID.group(conversation)
                request.retention.state = on ? .permanent : .ephemeralOneDay
                request.localID = DynamiteID.messageID(for: UUID().uuidString)
            })
    }
    public func roles(in conversation: ConversationID) -> [PersonID: MemberRole] { memberRoles[conversation] ?? [:] }
    /// `get_group_scoped_capabilities` for my membership, as web Chat asks when a conversation opens.
    public func permissions(in conversation: ConversationID) async throws -> ConversationPermissions {
        let group = try DynamiteID.group(conversation)
        let response: Dynamite_GetGroupScopedCapabilitiesResponse = try await rpc(
            "get_group_scoped_capabilities",
            Dynamite_GetGroupScopedCapabilitiesRequest.with { request in
                request.membershipIds = [
                    .with {
                        $0.memberID.userID.id = selfID
                        $0.groupID = group
                    }
                ]
            })
        let caps = response.entries.first?.capabilities
        return ConversationPermissions(
            editProfile: caps?.canEditSpaceProfile == true, manageMembers: caps?.canManageMembers == true,
            typing: caps.map { !$0.hasCanTriggerTypingIndicator || $0.canTriggerTypingIndicator } ?? true,
            editDetails: caps?.canEditDescription == true || caps?.canEditGuidelines == true,
            deleteSpace: caps?.canDeleteGroup == true, changeRoles: caps?.canUpdateMemberRoles == true,
            changeManagers: caps?.canUpdateManagerRoles == true, toggleHistory: caps?.canToggleHistory == true,
            reportMessages: caps?.canReportMessages == true,
            customEmoji: caps.flatMap { $0.hasCanViewOrUseCustomEmojis ? $0.canViewOrUseCustomEmojis : nil })
    }

    // ponytail: stops after 10 pages (1,000 members); raise it if a bigger space needs mentions of everyone.
    /// `list_members` as Google Chat's member-list sync sends it: joined members, 100 a page.
    public func members(of conversation: ConversationID) async throws -> [Person] {
        let group = try DynamiteID.group(conversation)
        var people: [Person] = []
        var token: String?
        for _ in 0..<10 {
            let request = Dynamite_ListMembersRequest.with { request in
                request.groupID = group
                request.memberTypes = [1, 5]
                request.membershipFilter = 4
                request.pageSize = 100
                request.flag8 = true
                if let token { request.pageToken = token }
            }
            let response: Dynamite_ListMembersResponse = try await rpc("list_members", request)
            people += response.members.filter { !$0.user.userID.id.isEmpty }.map { DynamiteMapper.person($0.user) }
            for membership in response.memberships where membership.hasRole {
                let role: MemberRole? =
                    switch membership.role {
                    case .owner: .owner
                    case .manager: .manager
                    case .member: .member
                    default: nil
                    }
                memberRoles[conversation, default: [:]][PersonID(membership.id.memberID.userID.id)] = role
            }
            guard !response.nextPageToken.isEmpty else { break }
            token = response.nextPageToken
        }
        // Counts only: whether Google sent each person's organisation, which marks someone "External".
        log.info(
            "members: \(people.count, privacy: .public), \(people.filter { $0.organization != nil }.count, privacy: .public) with an organisation"
        )
        let unnamed = people.filter { $0.name == "Unknown" }.map(\.id.rawValue)
        await resolve(unnamed)  // the page may carry ids only
        for person in people where self.people[person.id.rawValue] == nil || person.name != "Unknown" {
            self.people[person.id.rawValue] = person
        }
        return people.map { self.people[$0.id.rawValue] ?? $0 }
    }

    /// As web Chat does it: one person through `create_dm_extended`, two or more through `create_group` (a group DM);
    /// both return the conversation these people already share, or create it. People known only by email are invited by email.
    public func directMessage(with ids: [PersonID]) async throws -> Conversation {
        let others = ids.filter { $0.rawValue != selfID }
        guard !others.isEmpty else { throw DynamiteError.badID }
        let invitees = others.map(invitee)
        let group: Dynamite_GroupId?
        if others.count == 1 {
            let response: Dynamite_CreateDmResponse = try await rpc(
                "create_dm_extended",
                Dynamite_CreateDmRequest.with { request in
                    request.members = invitees
                    request.retentionSettings.state = .permanent  // history on
                    request.flag8 = false
                    request.spaceOrigin = 12  // SUGGESTED_CONTACT, as web Chat sends it
                })
            group = response.hasDm ? response.dm.groupID : nil
        } else {
            let response: Dynamite_CreateGroupResponse = try await rpc(
                "create_group",
                Dynamite_CreateGroupRequest.with { request in
                    request.space.name = ""
                    request.space.invitees = invitees.map { invitee in
                        .with {
                            $0.invitee = invitee
                            $0.field4 = 1
                            $0.field5 = 1
                        }
                    }
                    request.space.options.values = [0]
                    request.space.avatarInfo = .init()
                    request.space.groupType = 4  // FLAT_ROOM: a group DM
                    request.space.field15 = false
                    request.space.field17 = false
                    request.localID = DynamiteID.messageID(for: UUID().uuidString)
                    request.shouldFindExistingSpace = true
                    request.spaceOrigin = 9  // HUMAN, as web Chat sends it
                })
            group = response.hasGroup ? response.group.groupID : nil
        }
        guard let group, let id = DynamiteID.conversation(group) else { throw DynamiteError.malformedReply }
        await resolve(others.filter { Person.invitedEmail($0) == nil }.map(\.rawValue))
        // The sidebar item arrives with the server's pushed change; until then, what we know.
        let members = others.map { id in
            Person.invitedEmail(id).map(Person.invite(email:)) ?? people[id.rawValue] ?? Person(id: id, name: "Unknown")
        }
        let kind: ConversationKind = members.count == 1 ? .direct : .group
        return Conversation(
            id: id, name: members.map(\.name).sorted().joined(separator: ", "), kind: kind,
            members: [people[selfID] ?? Person(id: PersonID(selfID), name: "Me")] + members,
            avatarURL: kind == .direct ? members.first?.avatarURL : nil)
    }
    /// `block_entity`, as Google Chat's Block and report dialog sends it for a person.
    public func setPersonBlocked(_ blocked: Bool, for person: PersonID, dm: ConversationID?, report: Bool) async throws
    {
        let dmGroup = try dm.map(DynamiteID.group)
        let _: Dynamite_BlockEntityResponse = try await rpc(
            "block_entity",
            Dynamite_BlockEntityRequest.with { request in
                request.userID.id = person.rawValue
                request.blocked = blocked
                request.report = blocked && report
                if let dmGroup { request.dmGroupID = dmGroup }
            })
    }
    public func setSpaceBlocked(_ blocked: Bool, for space: ConversationID, report: Bool) async throws {
        let group = try DynamiteID.group(space)
        let _: Dynamite_BlockEntityResponse = try await rpc(
            "block_entity",
            Dynamite_BlockEntityRequest.with { request in
                request.groupID = group
                request.blocked = blocked
                request.report = blocked && report
            })
    }
    public func blockedPeople() async throws -> [PersonID] {
        let response: Dynamite_ListBlockedUsersResponse = try await rpc(
            "list_blocked_users", Dynamite_ListBlockedUsersRequest())
        return response.userIds.map(\.id).filter { !$0.isEmpty }.map { PersonID($0) }
    }
    public func blockedSpaces() async throws -> [BlockedSpace] {
        let response: Dynamite_ManageBlockedRoomsResponse = try await rpc(
            "manage_blocked_rooms", Dynamite_ManageBlockedRoomsRequest())
        return response.rooms.compactMap { room in
            DynamiteID.conversation(room.groupID).map { BlockedSpace(id: $0, name: room.name) }
        }
    }
    /// `report_message`: the message, its last update time, the reason and the (optional) explanation.
    public func reportMessage(_ message: Message, reason: ReportReason, explanation: String) async throws {
        let id = try DynamiteID.protoMessageID(message.id)
        let _: Dynamite_ReportMessageResponse = try await rpc(
            "report_message",
            Dynamite_ReportMessageRequest.with { request in
                request.messageID = id
                request.messageUpdateTime.micros =
                    message.lastUpdateMicros ?? Int64(message.createdAt.timeIntervalSince1970 * 1_000_000)
                request.reason.kind = Dynamite_ReportMessageRequest.Reason.Kind(rawValue: reason.rawValue) ?? .other
                request.explanation = .init()
                let text = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { request.explanation.text = text }
            })
    }
    /// `create_group` as web Chat's Create a space sends it: a name, an optional emoji, no members.
    public func createSpace(name: String, emoji: String?) async throws -> Conversation {
        let response: Dynamite_CreateGroupResponse = try await rpc(
            "create_group",
            Dynamite_CreateGroupRequest.with { request in
                request.space.name = name
                request.space.options.values = [1]
                request.space.avatarInfo = emoji.map { emoji in .with { $0.emoji.unicode = emoji } } ?? .init()
                request.space.groupType = 4
                request.space.field15 = false
                request.space.field17 = false
                request.localID = DynamiteID.messageID(for: UUID().uuidString)
                request.shouldFindExistingSpace = false
                request.spaceOrigin = 9  // HUMAN, as web Chat sends it
            })
        guard response.hasGroup, let id = DynamiteID.conversation(response.group.groupID) else {
            throw DynamiteError.malformedReply
        }
        // The sidebar item arrives with the server's pushed change; until then, what we know.
        return Conversation(
            id: id, name: name, kind: .space, members: [people[selfID] ?? Person(id: PersonID(selfID), name: "Me")],
            emoji: emoji)
    }
    /// `delete_group_v2`; a space without a linked Google Group deletes the space only, as Google Chat's Delete does.
    public func deleteSpace(_ conversation: ConversationID) async throws {
        let _: Dynamite_DeleteGroupResponse = try await rpc(
            "delete_group_v2",
            try Dynamite_DeleteGroupRequest.with { request in
                request.groupID = try DynamiteID.group(conversation)
                request.keepRoster = true
            })
    }
    /// `search_space_directory` as Google Chat's space browser sends it: one page of 20.
    public func searchSpaces(matching query: String) async throws -> [SpaceListing] {
        let response: Dynamite_SearchSpaceDirectoryResponse = try await rpc(
            "search_space_directory",
            Dynamite_SearchSpaceDirectoryRequest.with { request in
                request.pageSize = 20
                request.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                request.flag9 = false
            })
        return response.spaces.compactMap(DynamiteMapper.space)
    }
    /// `create_membership` with me as a JOINED member, as Google Chat joins from the space browser.
    public func join(_ space: SpaceListing) async throws -> Conversation {
        let response: Dynamite_CreateMembershipResponse = try await rpc(
            "create_membership",
            try Dynamite_CreateMembershipRequest.with { request in
                request.memberIds = [.with { $0.userID.id = selfID }]
                request.membershipState = .memberJoined
                request.groupID = try DynamiteID.group(space.id)
            })
        if response.results.first?.hasFailureReason == true { throw DynamiteError.joinRefused }
        return Conversation(
            id: space.id, name: space.name, kind: .space, members: [], emoji: space.emoji, avatarURL: space.avatarURL)
    }
}
