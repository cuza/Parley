import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Renaming a space or group, its emoji, adding and removing people, hiding it, and what I may change:
/// the requests Google Chat sends, network-stubbed.
extension AuthTests {
    /// GroupId {space_id(1) {space_id(1) "s1"}}.
    private static let groupS1 = Data([0x0A, 0x04, 0x0A, 0x02, 0x73, 0x31])
    private static func sent(_ exchange: StubExchange, _ path: String) -> [Data] {
        exchange.requests.filter { $0.url?.path == "/api/\(path)" }.map(Self.body)
    }

    /// update_group {name(2), update_masks(4) [NAME 1], group_id(11)}.
    @Test func renameSendsTheNameAndItsMask() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateGroupResponse())])
        try await backend.updateProfile("space/s1", name: "Ops", emoji: nil)
        let body = try #require(Self.sent(exchange, "update_group").first)
        #expect(body.starts(with: Data([0x12, 0x03]) + Data("Ops".utf8) + Data([0x20, 0x01, 0x5A, 0x06]) + Self.groupS1))
        #expect(try Dynamite_UpdateGroupRequest(serializedBytes: body).hasRequestHeader)
    }
    /// update_group {update_masks(4) [AVATAR 3], avatar_info(6) {emoji(1) {unicode(1)}}, group_id(11)}.
    @Test func emojiSendsTheAvatarAndItsMask() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateGroupResponse())])
        try await backend.updateProfile("space/s1", name: nil, emoji: "🚀")
        let rocket = Data("🚀".utf8)
        let body = try #require(Self.sent(exchange, "update_group").first)
        #expect(body.starts(with: Data([0x20, 0x03, 0x32, UInt8(rocket.count + 4), 0x0A, UInt8(rocket.count + 2), 0x0A, UInt8(rocket.count)])
                            + rocket + Data([0x5A, 0x06]) + Self.groupS1))
    }
    /// create_membership {group_id(4), invitees(8) [{invitee(1) {user_id(1), invitation_mode(3) GAIA_ID}, 4: 1, 5: 1}]},
    /// as web Chat adds someone to a space.
    @Test func addingPeopleInvitesThemByID() async throws {
        let added = Dynamite_CreateMembershipResponse.with { $0.results = [.with { $0.membership.membershipState = .memberInvited }] }
        let (backend, exchange) = try await Self.connected([try Self.proto(added)])
        try await backend.addMembers(["u1"], to: "space/s1")
        let body = try #require(Self.sent(exchange, "create_membership").first)
        let invitee = Data([0x0A, 0x08, 0x0A, 0x04, 0x0A, 0x02, 0x75, 0x31, 0x18, 0x01, 0x20, 0x01, 0x28, 0x01])
        #expect(body.starts(with: Data([0x22, 0x06]) + Self.groupS1 + Data([0x42, UInt8(invitee.count)]) + invitee))
        #expect(try Dynamite_CreateMembershipRequest(serializedBytes: body).hasRequestHeader)
    }
    @Test func aRefusedAddThrows() async throws {
        let refused = Dynamite_CreateMembershipResponse.with { $0.results = [.with { $0.failureReason = 5 }] }
        let (backend, _) = try await Self.connected([try Self.proto(refused)])
        await #expect(throws: DynamiteError.addRefused) { try await backend.addMembers(["u1"], to: "space/s1") }
    }
    /// remove_memberships {member_ids(1) [{user_id(1) {id(1)}}], group_id(2)}: leave's request with someone else's id.
    @Test func removingSomeoneSendsTheirID() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_RemoveMembershipsResponse.with { $0.results = [.init()] })])
        try await backend.removeMember("u1", from: "space/s1")
        let body = try #require(Self.sent(exchange, "remove_memberships").first)
        #expect(body.starts(with: Data([0x0A, 0x06, 0x0A, 0x04, 0x0A, 0x02, 0x75, 0x31, 0x12, 0x06]) + Self.groupS1))
    }
    /// hide_group {group_id(1), hidden(2)}; showing it again sends hidden = false explicitly.
    @Test func hideSendsTheFlag() async throws {
        let done = try Self.proto(Dynamite_HideGroupResponse())
        let (backend, exchange) = try await Self.connected([done, done])
        try await backend.setHidden(true, conversation: "space/s1")
        try await backend.setHidden(false, conversation: "space/s1")
        let bodies = Self.sent(exchange, "hide_group")
        #expect(bodies.first?.starts(with: Data([0x0A, 0x06]) + Self.groupS1 + Data([0x10, 0x01])) == true)
        #expect(bodies.last?.starts(with: Data([0x0A, 0x06]) + Self.groupS1 + Data([0x10, 0x00])) == true)
    }
    /// get_group_scoped_capabilities {membership_ids(1) [{member_id(1) {user_id(1) {id "me"}}, group_id(3)}]};
    /// the answer's flags 9 (name and emoji) and 14 (members) decide what is offered.
    @Test func permissionsComeFromMyCapabilities() async throws {
        let caps = Dynamite_GetGroupScopedCapabilitiesResponse.with {
            $0.entries = [.with { $0.capabilities.canEditSpaceProfile = false; $0.capabilities.canManageMembers = true }]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(caps)])
        let permissions = try await backend.permissions(in: "space/s1")
        #expect(permissions == ConversationPermissions(editProfile: false, manageMembers: true))
        let body = try #require(Self.sent(exchange, "get_group_scoped_capabilities").first)
        #expect(body.starts(with: Data([0x0A, 0x10, 0x0A, 0x06, 0x0A, 0x04, 0x0A, 0x02, 0x6D, 0x65, 0x1A, 0x06]) + Self.groupS1))
    }
    /// The sidebar read still lists a hidden conversation, its read state carrying the hide time (field 9, µs):
    /// it comes back marked hidden, for Settings to list and the sidebar to leave out, as Google Chat does.
    @Test func hiddenConversationsComeBackMarked() async throws {
        let world = try Self.proto(Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [.with { $0.groupID.spaceID.spaceID = "s1"; $0.roomName = "Hidden"; $0.readState.hideTimestamp = 1_791_642_401_602_341 },
                             .with { $0.groupID.spaceID.spaceID = "s2"; $0.roomName = "Shown" }]
        })
        let (backend, _) = try await Self.connected([world])
        let rooms = try await backend.conversations()
        #expect(rooms.map(\.id).sorted() == ["space/s1", "space/s2"])
        #expect(rooms.first { $0.id == "space/s1" }?.hidden == DynamiteMapper.date(1_791_642_401_602_341))
        #expect(rooms.first { $0.id == "space/s2" }?.hidden == nil)
    }
    /// GROUP_HIDE_CHANGED (16), body 15 {group_id(1), hidden(2)}: hidden elsewhere, the conversation is read again and
    /// comes back marked hidden even when the read still shows it; shown again, it comes back unmarked.
    @Test func hiddenElsewhereMarksTheConversation() async throws {
        let shown = try Self.proto(Dynamite_PaginatedWorldResponse.with { $0.worldItems = [.with { $0.groupID.spaceID.spaceID = "s1"; $0.roomName = "Ops" }] })
        let (backend, _) = try await Self.connected([shown, shown])
        for hidden in [true, false] {
            await backend.handle(.with {
                $0.event.bodies = [.with { $0.eventType = .groupHideChanged; $0.groupHideChanged.groupID.spaceID.spaceID = "s1"; $0.groupHideChanged.hidden = hidden }]
            })
        }
        let rooms = Self.rooms(await Self.drain(backend))
        #expect(rooms.map(\.id) == ["space/s1", "space/s1"])
        #expect(rooms.first?.hidden != nil && rooms.last?.hidden == nil)
    }
}

/// The same actions in the store: shown at once, put back when the server refuses.
@MainActor
struct ManageGroupsStoreTests {
    private func started() async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        return (store, fake)
    }
    private func room(_ store: ChatStore, _ id: ConversationID) -> Conversation? { store.conversations.first { $0.id == id } }

    @Test func renameShowsAtOnceAndIsPutBackWhenRefused() async throws {
        let (store, fake) = await started()
        await store.rename("design", to: "  Studio  ")
        #expect(room(store, "design")?.name == "Studio")
        #expect(await fake.changes == ["rename Studio design"])
        await fake.simulateChangeFailure()
        await store.rename("design", to: "Nope")
        #expect(room(store, "design")?.name == "Studio" && store.error != nil)
    }
    @Test func anEmptyOrUnchangedNameIsNotSent() async throws {
        let (store, fake) = await started()
        await store.rename("design", to: "   ")
        await store.rename("design", to: "Design studio")
        #expect(await fake.changes.isEmpty)
    }
    @Test func emojiShowsAtOnce() async throws {
        let (store, fake) = await started()
        await store.setEmoji("🚀", "design")
        #expect(room(store, "design")?.emoji == "🚀")
        #expect(await fake.changes == ["emoji 🚀 design"])
    }
    @Test func addedPeopleJoinTheRoster() async throws {
        let (store, fake) = await started()
        await store.loadMembers("engineering")
        let maria = try #require(store.conversations.first { $0.id == "maria" }?.members.first { $0.id == "maria" })
        await store.addMembers([maria], to: "engineering")
        #expect(await fake.changes == ["add maria engineering"])
        #expect(store.members["engineering"]?.contains { $0.id == "maria" } == true)
    }
    @Test func removedPeopleLeaveTheRosterAndComeBackWhenRefused() async throws {
        let (store, fake) = await started()
        await store.loadMembers("design")
        await store.removeMember("alex", from: "design")
        #expect(store.members["design"]?.contains { $0.id == "alex" } == false)
        await store.loadMembers("general")
        await fake.simulateChangeFailure()
        await store.removeMember("alex", from: "general")
        #expect(store.members["general"]?.contains { $0.id == "alex" } == true && store.error != nil)
    }
    @Test func hideTakesItOffTheSidebarAndARefusalPutsItBack() async throws {
        let (store, fake) = await started()
        let index = try #require(store.conversations.firstIndex { $0.id == "general" })
        await fake.simulateChangeFailure()
        await store.hide("general")
        #expect(store.conversations.firstIndex { $0.id == "general" } == index && store.error != nil)
        store.error = nil
        await store.hide("general")
        #expect(room(store, "general") == nil && store.error == nil)
        #expect(store.hidden.map(\.id) == ["general"])
        try await store.refresh()
        #expect(room(store, "general") == nil && store.hidden.map(\.id) == ["general"])
    }
    @Test func unhideSendsItAndPutsItBackInTheSidebar() async throws {
        let (store, fake) = await started()
        await store.hide("general")
        await store.unhide("general")
        #expect(await fake.changes == ["hide general", "unhide general"])
        #expect(store.hidden.isEmpty && room(store, "general")?.hidden == nil)
        try await store.refresh()
        #expect(store.hidden.isEmpty && room(store, "general") != nil)
    }
    @Test func aRefusedUnhideKeepsItHidden() async throws {
        let (store, fake) = await started()
        await store.hide("general")
        await fake.simulateChangeFailure()
        await store.unhide("general")
        #expect(store.hidden.map(\.id) == ["general"] && room(store, "general") == nil && store.error != nil)
    }
    /// Hidden or shown again on another device: the pushed conversation moves between the sidebar and the hidden list.
    @Test func aPushedHideMovesTheConversation() async throws {
        let (store, _) = await started()
        var general = try #require(room(store, "general"))
        general.hidden = .now
        store.apply(.conversationUpserted(general))
        #expect(room(store, "general") == nil && store.hidden.map(\.id) == ["general"])
        general.hidden = nil
        store.apply(.conversationUpserted(general))
        #expect(room(store, "general") != nil && store.hidden.isEmpty)
    }
    /// Only what the server allows is offered: General is a space where I am a plain member.
    @Test func permissionsAreLoadedPerConversation() async throws {
        let (store, _) = await started()
        await store.loadPermissions("design")
        await store.loadPermissions("general")
        #expect(store.permissions["design"] == ConversationPermissions(editProfile: true, manageMembers: true))
        #expect(store.permissions["general"] == ConversationPermissions())
    }
    /// A membership change pushed from elsewhere re-reads a member list already on screen.
    @Test func aChangedConversationReloadsItsLoadedMembers() async throws {
        let (store, fake) = await started()
        await store.loadMembers("design")
        let before = await fake.memberRequests.count
        let design = try #require(room(store, "design"))
        store.apply(.conversationUpserted(design))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.memberRequests.count == before + 1)
    }
}
