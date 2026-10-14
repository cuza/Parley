import Foundation
import Testing
@testable import Parley

/// Conversations as Shortcuts and Siri see them: what's suggested before anything is typed, and what a typed name finds.
struct ConversationEntityTests {
    static func room(_ id: String, _ name: String, _ kind: ConversationKind = .space, pinned: Bool = false, hoursAgo: Double? = nil, hidden: Bool = false) -> Conversation {
        var room = Conversation(id: id, name: name, kind: kind, members: [], pinned: pinned)
        room.activity = hoursAgo.map { Date(timeIntervalSince1970: 1_700_000_000 - $0 * 3600) }
        if hidden { room.hidden = .now }
        return room
    }
    @Test func pinnedFirstThenRecentTenAtMost() {
        let rooms = [Self.room("space/a", "Old", hoursAgo: 50), Self.room("space/b", "Pinned", pinned: true, hoursAgo: 90),
                     Self.room("space/c", "Hidden", hoursAgo: 1, hidden: true), Self.room("space/d", "New", hoursAgo: 2)]
            + (0..<12).map { Self.room("space/x\($0)", "Filler \($0)", hoursAgo: 100 + Double($0)) }
        let suggested = ConversationEntity.suggested(rooms)
        #expect(suggested.prefix(3).map(\.name) == ["Pinned", "New", "Old"])
        #expect(suggested.count == 10 && !suggested.contains { $0.name == "Hidden" })
    }
    @Test func aTypedNameFindsConversationsContainingIt() {
        let rooms = [Self.room("space/a", "Design team"), Self.room("dm/b", "Maria Chen", .direct), Self.room("space/c", "Résumé reviews")]
        #expect(ConversationEntity.matching("design", in: rooms).map(\.id) == ["space/a"])
        #expect(ConversationEntity.matching("resume", in: rooms).map(\.id) == ["space/c"])   // as Finder matches: case and accents aside
    }
    @Test func eachKindHasItsSubtitle() {
        var app = Self.room("dm/g", "Gemini", .direct); app.app = .gemini
        #expect([Self.room("space/a", "A"), Self.room("dm/b", "B", .direct), Self.room("dm/c", "C", .group), app].map(ConversationEntity.kindName)
                == ["Space", "Direct message", "Group chat", "App"])
    }
}

/// What Siri gets for the conversation on screen: its Google Chat link.
struct ConversationTransferTests {
    @Test func aConversationTransfersAsItsLink() async throws {
        guard #available(macOS 15.2, *) else { return }
        let entity = ConversationEntity(Conversation(id: "space/AAAAexample", name: "Design", kind: .space, members: []))
        let data = try await entity.exported(as: .url)
        #expect(URL(dataRepresentation: data, relativeTo: nil) == ChatLink.url("space/AAAAexample"))
    }
}
