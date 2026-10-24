import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Custom sidebar sections, shared with the web: my sections take their conversations out of the default ones,
/// and every section follows my order.
struct SidebarSectionsLayoutTests {
    private func room(_ id: String, _ kind: ConversationKind, section: String? = nil, app: Conversation.App? = nil)
        -> Conversation
    {
        var room = Conversation.fixture(ConversationID(id), kind: kind, name: id, app: app)
        room.section = section
        return room
    }
    @Test func myOwnSectionsSitWhereIPutThem() {
        let rooms = [
            room("a", .direct), room("b", .space, section: "k1"), room("c", .space), room("d", .direct, app: .bot),
            room("e", .space, section: "gone"),
        ]
        let sections = [
            SidebarSection(kind: .shortcuts, position: 0), SidebarSection(kind: .directMessages, position: 1),
            SidebarSection(kind: .custom, key: "k1", name: "Projects", position: 2),
            SidebarSection(kind: .spaces, position: 3),
            SidebarSection(kind: .apps, position: 4),
        ]
        let laid = Conversation.sidebarSections(rooms, custom: sections)
        #expect(laid.map(\.title) == ["Shortcuts", "Pinned", "Direct messages", "Projects", "Spaces", "Apps"])
        #expect(laid.first { $0.title == "Projects" }?.rooms.map(\.id) == ["b"])
        #expect(
            laid.first { $0.title == "Spaces" }?.rooms.map(\.id) == ["c", "e"],
            "a section that no longer exists leaves its conversations in place")
    }
    @Test func withoutSectionsTheSidebarIsAsBefore() {
        let laid = Conversation.sidebarSections([room("a", .direct), room("c", .space)])
        #expect(laid.map(\.title) == ["Shortcuts", "Pinned", "Direct messages", "Spaces", "Apps"])
    }
}

/// The section requests, as web Chat sends them.
extension NetworkTests { @Suite struct SidebarSectionsTests: NetworkSuite {} }

extension NetworkTests.SidebarSectionsTests {
    @Test func sectionsAreCreatedRenamedMovedAndDeletedAsWebSendsThem() async throws {
        let made = Dynamite_CreateRosterSectionResponse.with {
            $0.section = .with { section in
                section.id = .with {
                    $0.type = 3
                    $0.label = .with {
                        $0.type = 4
                        $0.value = "757"
                    }
                    $0.secondaryKey = "757"
                }
                section.name = "Projects"
                section.sortOrder = 3
            }
        }
        let replies =
            try [Self.proto(made)] + (0..<5).map { _ in try Self.proto(Dynamite_UpdateRosterSectionResponse()) }
        let (backend, exchange) = try await Self.connected(replies)
        let section = try await backend.createSection(named: "Projects", at: 3)
        let create = try Dynamite_CreateRosterSectionRequest(
            serializedBytes: Self.body(exchange.requests[exchange.requests.count - 1]))
        #expect(
            create.section.id.type == 3 && create.section.id.label.value == "1" && create.section.name == "Projects"
                && create.section.sortOrder == 3)
        #expect(section == SidebarSection(kind: .custom, key: "757", name: "Projects", position: 3))
        try await backend.renameSection(section, to: "Work")
        let rename = try Dynamite_UpdateRosterSectionRequest(
            serializedBytes: Self.body(exchange.requests[exchange.requests.count - 1]))
        #expect(
            rename.mask.fields == [3] && rename.section.name == "Work" && rename.section.id.secondaryKey == "757"
                && rename.section.id.label.type == 4)
        try await backend.moveSection(section, to: 2)
        let move = try Dynamite_UpdateRosterSectionRequest(
            serializedBytes: Self.body(exchange.requests[exchange.requests.count - 1]))
        #expect(move.mask.fields == [2] && move.section.sortOrder == 2)
        try await backend.moveConversation("space/s9", to: "757", from: "111")
        let removed = try Dynamite_GroupLabelRequest(
            serializedBytes: Self.body(exchange.requests[exchange.requests.count - 2]))
        let applied = try Dynamite_GroupLabelRequest(
            serializedBytes: Self.body(exchange.requests[exchange.requests.count - 1]))
        #expect(
            exchange.requests[exchange.requests.count - 2].url?.path == "/api/remove_group_label"
                && removed.label.value == "111")
        #expect(
            exchange.requests.last?.url?.path == "/api/apply_group_label" && applied.label.type == 4
                && applied.label.value == "757" && applied.groupID.spaceID.spaceID == "s9")
        try await backend.deleteSection(section)
        let delete = try Dynamite_DeleteRosterSectionRequest(
            serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(exchange.requests.last?.url?.path == "/api/delete_roster_section" && delete.id.secondaryKey == "757")
    }
    @Test func aConversationsSectionComesFromItsReadStateLabel() throws {
        let item = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "Plans"
            $0.readState.labels = [
                .with {
                    $0.type = 4
                    $0.value = "757"
                }
            ]
        }
        #expect(try #require(DynamiteMapper.conversation(item, selfID: "me", people: [:])).section == "757")
    }
}

@MainActor struct SidebarSectionsStoreTests {
    @Test func aNewSectionTakesTheConversationAndDeletingItGivesItBack() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.createSection(" Projects ", moving: "design")
        let made = try #require(store.rooms.sections.first { $0.kind == .custom })
        #expect(made.name == "Projects" && store.rooms.conversations.first { $0.id == "design" }?.section == made.key)
        await store.renameSection(made, to: "Work")
        #expect(store.rooms.sections.first { $0.key == made.key }?.name == "Work")
        await store.moveConversation("design", to: nil)
        #expect(store.rooms.conversations.first { $0.id == "design" }?.section == nil)
        await store.moveConversation("design", to: made.key)
        await store.deleteSection(made)
        #expect(store.rooms.sections.isEmpty && store.rooms.conversations.first { $0.id == "design" }?.section == nil)
    }
}
