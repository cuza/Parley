import Foundation
import Testing
@testable import Parley

/// A space's settings, as Google Chat sends them: details, member roles and history.
extension AuthTests {
    @Test func detailsAreSavedTogetherUnderTheDetailsMask() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateGroupResponse())])
        try await backend.updateDetails("space/s9", description: "Ops", guidelines: "Be kind")
        let sent = try Dynamite_UpdateGroupRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(sent.updateMasks == [.details] && sent.groupDetails.description_p == "Ops" && sent.groupDetails.guidelines == "Be kind")
        #expect(sent.groupID.spaceID.spaceID == "s9" && !sent.hasName)
    }
    @Test func aRoleChangeNamesThePersonTheSpaceAndTheRole() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateMembershipRoleResponse())])
        try await backend.setRole(.manager, of: "u1", in: "space/s9")
        let sent = try Dynamite_UpdateMembershipRoleRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(exchange.requests.last?.url?.path == "/api/update_membership_role")
        #expect(sent.changes.count == 1 && sent.changes[0].role == .manager)
        #expect(sent.changes[0].userID.id == "u1" && sent.changes[0].groupID.spaceID.spaceID == "s9")
    }
    @Test func historyOffSendsTheOneDayStateAndAMessageID() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateGroupRetentionSettingsResponse())])
        try await backend.setHistory(false, in: "space/s9")
        let sent = try Dynamite_UpdateGroupRetentionSettingsRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(sent.retention.state == .ephemeralOneDay && sent.groupID.spaceID.spaceID == "s9" && sent.localID.count == 11)
    }
    @Test func rolesComeWithTheMemberList() async throws {
        let listed = Dynamite_ListMembersResponse.with { r in
            r.members = [.with { $0.user.userID.id = "u1"; $0.user.name = "Maria" }, .with { $0.user.userID.id = "u2"; $0.user.name = "Alex" }]
            r.memberships = [("u1", Dynamite_MemberRole.owner), ("u2", .manager)].map { id, role in
                .with { $0.id.memberID.userID.id = id; $0.role = role }
            }
        }
        let (backend, _) = try await Self.connected([try Self.proto(listed)])
        _ = try await backend.members(of: "space/s9")
        #expect(await backend.roles(in: "space/s9") == ["u1": .owner, "u2": .manager])
    }
    @Test func permissionsReadEverySettingsCapability() async throws {
        let caps = Dynamite_GetGroupScopedCapabilitiesResponse.with {
            $0.entries = [.with { $0.capabilities = .with { c in
                c.canEditDescription = true; c.canEditGuidelines = true; c.canDeleteGroup = true
                c.canUpdateMemberRoles = true; c.canUpdateManagerRoles = false; c.canToggleHistory = true
            } }]
        }
        let (backend, _) = try await Self.connected([try Self.proto(caps)])
        let allowed = try await backend.permissions(in: "space/s9")
        #expect(allowed.editDetails && allowed.deleteSpace && allowed.changeRoles && !allowed.changeManagers && allowed.toggleHistory)
    }
}

struct SpaceHistoryMappingTests {
    @Test func aSidebarItemCarriesHistoryAndGuidelines() throws {
        let off = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"; $0.roomName = "Plans"
            $0.groupLite.retention.state = .ephemeralOneDay
            $0.groupLite.spaceDetails = .with { $0.description_p = "Ops"; $0.guidelines = "Be kind" }
        }
        let room = try #require(DynamiteMapper.conversation(off, selfID: "me", people: [:]))
        #expect(room.historyOff == true && room.guidelines == "Be kind")
        let on = Dynamite_WorldItemLite.with { $0.groupID.spaceID.spaceID = "s"; $0.roomName = "Plans"; $0.groupLite.retention.state = .permanent }
        #expect(try #require(DynamiteMapper.conversation(on, selfID: "me", people: [:])).historyOff == false)
    }
}

@MainActor struct SpaceSettingsStoreTests {
    @Test func settingsChangeAtOnceAndReachTheServer() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.updateDetails("design", description: "New", guidelines: "Rules")
        await store.setHistory(false, in: "design")
        await store.setRole(.manager, of: "maria", in: "design")
        let room = try #require(store.conversations.first { $0.id == "design" })
        #expect(room.description == "New" && room.guidelines == "Rules" && room.historyOff == true)
        #expect(store.roles["design"]?["maria"] == .manager)
        #expect(await fake.changes.suffix(3) == ["details design", "history off design", "role manager maria design"])
    }
    @Test func theComposerSaysWhenHistoryIsOff() {
        var room = Conversation(id: "s", name: "S", kind: .space, members: [])
        #expect(ChatView.composerPrompt(room) == "Message")
        room.historyOff = true
        #expect(ChatView.composerPrompt(room) == "History is off")
    }
}
