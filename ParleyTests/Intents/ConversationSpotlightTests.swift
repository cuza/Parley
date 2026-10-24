import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Conversations in Spotlight: names and members only. The first update of a launch, or another account's, rebuilds the
/// index; after that only conversations whose name, members or pin changed are indexed again, and only removed ones are
/// deleted. Never for an unread count.
@MainActor struct ConversationSpotlightTests {
    static func room(_ id: String, _ name: String, members: [Person] = [], pinned: Bool = false) -> Conversation {
        Conversation.fixture(ConversationID(id), name: name, members: members, pinned: pinned)
    }
    @Test func indexesOnlyWhatChanged() async {
        var changes: [ConversationSpotlight.Change] = []
        let spotlight = ConversationSpotlight { change, _ in changes.append(change) }
        var design = Self.room("space/a", "Design team", members: [Person(id: "u1", name: "Maria")])
        let launch = Self.room("space/b", "Launch")
        var hidden = Conversation.fixture("dm/c", kind: .direct, name: "Old chat")
        hidden.hidden = .now
        await spotlight.update([design, launch, hidden], me: "me")
        #expect(changes.last?.clearAll == true && changes.last?.conversations.map(\.name) == ["Design team", "Launch"])  // the hidden one never
        design.unread = 3
        await spotlight.update([design, launch, hidden], me: "me")  // an unread count: nothing to index
        #expect(changes.count == 1)
        design.name = "Design studio"
        await spotlight.update([design, launch, hidden], me: "me")
        #expect(
            changes.last?.clearAll == false && changes.last?.conversations.map(\.name) == ["Design studio"]
                && changes.last?.removed == [])
        await spotlight.update([design, hidden], me: "me")  // Launch left
        #expect(changes.last?.conversations == [] && changes.last?.removed == ["space/b"])
        await spotlight.update([design], me: "someone else")  // another account: rebuilt from scratch
        #expect(changes.last?.clearAll == true)
        #expect(changes.count == 4)
    }
    /// Pinned, then recent: the conversations Shortcuts suggests rank higher in Spotlight too; a pin re-indexes its row.
    @Test func suggestedConversationsRankHigher() async {
        var changes: [ConversationSpotlight.Change] = []
        let spotlight = ConversationSpotlight { change, _ in changes.append(change) }
        var design = Self.room("space/a", "Design team")
        let rest = (0..<12).map { Self.room("space/x\($0)", "Room \($0)") }
        await spotlight.update([design] + rest, me: "me")
        #expect(changes.last?.prioritized == Set(ConversationEntity.suggested([design] + rest).map(\.id)))
        design.pinned = true
        await spotlight.update([design] + rest, me: "me")
        #expect(
            changes.last?.conversations.map(\.id) == ["space/a"]
                && changes.last?.prioritized.contains("space/a") == true)
    }
    @Test func membersAreKeywords() {
        let room = Conversation.fixture(
            "space/a", name: "Design team",
            members: [Person(id: "u1", name: "Maria Chen"), Person(id: "u2", name: "Alex")])
        #expect(ConversationEntity(room).keywords == ["Maria Chen", "Alex"])
    }
}
