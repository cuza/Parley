import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Space invitations, as Google Chat keeps them: the space directory lists an invited space with my membership
/// INVITED (1); joining it is the same create_membership as joining any space.
@MainActor struct SpaceInvitationTests {
    @Test func theDirectorysInvitedStateBecomesAnInvitation() throws {
        let entry = Dynamite_SpaceDirectoryEntry.with {
            $0.groupID.spaceID.spaceID = "s9"
            $0.name = "Plans"
            $0.membershipState = .memberInvited
        }
        let listing = try #require(DynamiteMapper.space(entry))
        #expect(listing.invited && !listing.joined)
    }
    /// The sidebar's invitation row opens New Chat, so an invitation has to be in sight there, above every person.
    @Test func invitationsComeBeforePeopleInNewChat() {
        let invite = SpaceListing(id: "space/b", name: "Beta", invited: true)
        let open = SpaceListing(id: "space/a", name: "Alpha")
        let results = PaletteResults(
            query: "", conversations: [], people: [Person(id: "maria", name: "Maria Chen")], spaces: [open, invite],
            picked: [])
        #expect(results.invitations.map(\.id) == ["space/b"] && results.spaces.map(\.id) == ["space/a"])
        #expect(results.items.map(\.id) == ["s:space/b", "p:maria", "s:space/a"])
    }
    @Test func aSpaceOfOneSaysMember() {
        #expect(
            SpaceListing.detail(SpaceListing(id: "s", name: "S", memberCount: 1, invited: true)) == "Invited · 1 member"
        )
        #expect(SpaceListing.detail(SpaceListing(id: "s", name: "S", memberCount: 3)) == "3 members")
        #expect(SpaceListing.detail(SpaceListing(id: "s", name: "S")) == nil)
    }
    /// An invitation that arrives while Parley runs shows on the next read, every few minutes while Parley is in front;
    /// a failed read keeps what was there.
    @Test func invitationsAreReadAgainWhileParleyRuns() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        store.now = { clock }
        await store.start()
        #expect(store.rooms.invitations.isEmpty)
        await fake.invite(SpaceListing(id: "space/plans", name: "Plans", invited: true))
        clock += 60
        await store.refreshInvitations()
        #expect(store.rooms.invitations.isEmpty)  // read at launch a minute ago
        clock += ChatStore.invitationsTTL
        await store.refreshInvitations()
        #expect(store.rooms.invitations.map(\.id) == ["space/plans"])
        await fake.simulateDirectoryFailure()
        clock += ChatStore.invitationsTTL
        await store.refreshInvitations()
        #expect(store.rooms.invitations.map(\.id) == ["space/plans"])
    }
    @Test func theStoreKeepsInvitationsUntilJoined() async throws {
        let fake = FakeBackend()
        await fake.invite(SpaceListing(id: "space/plans", name: "Plans", invited: true))
        let store = ChatStore(backend: fake)
        await store.start()
        #expect(store.rooms.invitations.map(\.id) == ["space/plans"])
        try await store.join(store.rooms.invitations[0])
        #expect(store.rooms.invitations.isEmpty && store.rooms.conversations.contains { $0.id == "space/plans" })
    }
}

@MainActor struct InvitationRowTests {
    @Test func theSidebarRowCountsInvitations() {
        #expect(ChatView.invitationsTitle(1) == "1 space invitation")
        #expect(ChatView.invitationsTitle(3) == "3 space invitations")
    }
}
