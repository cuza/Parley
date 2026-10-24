import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Conversations and people from outside the organisation, as Google Chat marks them "External".
@MainActor struct ExternalTests {
    /// The conversation list's guest access (field 10) is ENABLED (2) where people outside the organisation take part.
    @Test func aConversationWithGuestAccessIsExternal() {
        let item = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "S"
            $0.guestAccess.state = .guestAccessEnabled
        }
        #expect(DynamiteMapper.conversation(item, selfID: "me", people: [:])?.external == true)
        let inside = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "S"
            $0.guestAccess.state = .guestAccessDisabled
        }
        #expect(DynamiteMapper.conversation(inside, selfID: "me", people: [:])?.external == false)
        let unstated = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "S"
        }
        #expect(DynamiteMapper.conversation(unstated, selfID: "me", people: [:])?.external == nil)
    }
    /// A person's organisation (User field 12): a personal account, or a Workspace customer.
    @Test func aPersonCarriesTheirOrganisation() {
        #expect(
            DynamiteMapper.person(
                .with {
                    $0.userID.id = "a"
                    $0.organization.consumer = .init()
                }
            ).organization == .consumer)
        #expect(
            DynamiteMapper.person(
                .with {
                    $0.userID.id = "a"
                    $0.organization.customer.customerID.customerID = "C1"
                }
            ).organization == .customer("C1"))
        #expect(DynamiteMapper.person(.with { $0.userID.id = "a" }).organization == nil)
    }
    /// The launch cache keeps an organisation as Google Chat's own spelling, as caches written before the enum have it.
    @Test func aCachedOrganisationKeepsItsFormat() throws {
        let old = Data(
            #"[{"id":"a","name":"A","presence":"offline","organization":"customer:C1"},{"id":"b","name":"B","presence":"offline","organization":"consumer"}]"#
                .utf8)
        let people = try JSONDecoder().decode([Person].self, from: old)
        #expect(people.map(\.organization) == [.customer("C1"), .consumer])
        let written = try #require(String(data: try JSONEncoder().encode(people), encoding: .utf8))
        #expect(written.contains(#""organization":"customer:C1""#) && written.contains(#""organization":"consumer""#))
        // In a whole launch cache: the conversation and its members' organisations come back.
        let snapshot = LaunchSnapshot(
            accountID: "me", conversations: [Conversation.fixture("space/s", name: "S", members: people)])
        let read = try JSONDecoder().decode(LaunchSnapshot.self, from: try JSONEncoder().encode(snapshot))
        #expect(read.conversations.first?.members.map(\.organization) == [.customer("C1"), .consumer])
    }
    /// As Google Chat decides it: someone is external when their organisation isn't mine. Nobody is, to a personal
    /// account; and an unknown organisation is not called external.
    @Test func someoneFromAnotherOrganisationIsExternal() {
        let me = Person(id: "me", name: "Me", organization: .customer("C1"))
        #expect(ChatStore.external(Person(id: "g", name: "Guest", organization: .consumer), to: me))
        #expect(ChatStore.external(Person(id: "o", name: "Other", organization: .customer("C2")), to: me))
        #expect(!ChatStore.external(Person(id: "c", name: "Colleague", organization: .customer("C1")), to: me))
        #expect(!ChatStore.external(Person(id: "u", name: "Unknown"), to: me))
        #expect(!ChatStore.external(me, to: me))
        #expect(
            !ChatStore.external(
                Person(id: "o", name: "Other", organization: .customer("C2")),
                to: Person(id: "me", name: "Me", organization: .consumer)))
    }
    /// Google Chat's own word wins: custom emoji follow the conversation's capability where it was read, and its
    /// external mark until then.
    @Test func theCapabilityDecidesCustomEmoji() async throws {
        let fake = FakeBackend()
        var outside = Conversation.fixture("space/out", name: "Out")
        outside.external = true
        let store = ChatStore(
            backend: fake,
            cache: try CustomEmojiLaunchTests.cache(LaunchSnapshot(accountID: "me", conversations: [outside])))
        #expect(!store.allowsCustomEmoji(in: "space/out"))
        await fake.simulateCustomEmoji(true, in: "space/out")
        await store.loadPermissions("space/out")
        #expect(store.allowsCustomEmoji(in: "space/out"))
    }
}
