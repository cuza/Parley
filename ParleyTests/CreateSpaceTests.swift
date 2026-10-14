import Foundation
import Testing
@testable import Parley

/// Creating and deleting a space, as web Chat sends them.
extension AuthTests {
    @Test func aNewSpaceIsCreateGroupWithANameAndTheSpaceOptions() async throws {
        let made = Dynamite_CreateGroupResponse.with { $0.group.groupID.spaceID.spaceID = "s42" }
        let (backend, exchange) = try await Self.connected([try Self.proto(made)])
        let room = try await backend.createSpace(name: "Launch", emoji: "🚀")
        let sent = try Dynamite_CreateGroupRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(sent.space.name == "Launch" && sent.space.groupType == 4 && sent.space.options.values == [1])
        #expect(sent.space.avatarInfo.emoji.unicode == "🚀" && sent.space.invitees.isEmpty && !sent.shouldFindExistingSpace)
        #expect(sent.spaceOrigin == 9 && sent.localID.count == 11)
        #expect(room.id == "space/s42" && room.kind == .space && room.name == "Launch" && room.emoji == "🚀")
    }
    @Test func deletingASpaceDeletesOnlyTheSpace() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_DeleteGroupResponse())])
        try await backend.deleteSpace("space/s42")
        let sent = try Dynamite_DeleteGroupRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(exchange.requests.last?.url?.path == "/api/delete_group_v2" && sent.groupID.spaceID.spaceID == "s42" && sent.keepRoster)
    }
}

@MainActor struct CreateSpaceStoreTests {
    @Test func aCreatedSpaceOpensAndADeletedOneLeavesTheSidebar() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        try await store.createSpace(name: "  Launch  ", emoji: nil)
        let room = try #require(store.conversations.first { $0.name == "Launch" })
        #expect(room.kind == .space && store.selectedID == room.id)
        await store.deleteSpace(room.id)
        #expect(!store.conversations.contains { $0.id == room.id } && store.selectedID != room.id)
    }
    @Test func aSpaceNeedsAName() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let before = store.conversations.count
        await #expect(throws: (any Error).self) { try await store.createSpace(name: "   ", emoji: nil) }
        #expect(store.conversations.count == before)
    }
}
