import Foundation
import Testing
@testable import Parley

/// Conversations in Spotlight: names and members only, rebuilt when those change, never for an unread count.
@MainActor struct ConversationSpotlightTests {
    @Test func rebuildsOnlyWhenNamesOrMembersChange() async {
        var indexed: [[String]] = []
        let spotlight = ConversationSpotlight { conversations, _ in indexed.append(conversations.map(\.name)) }
        var design = Conversation(id: "space/a", name: "Design team", kind: .space, members: [Person(id: "u1", name: "Maria")])
        var hidden = Conversation(id: "dm/b", name: "Old chat", kind: .direct, members: [])
        hidden.hidden = .now
        await spotlight.update([design, hidden], me: "me")
        design.unread = 3
        await spotlight.update([design, hidden], me: "me")   // an unread count: nothing to index
        design.name = "Design studio"
        await spotlight.update([design, hidden], me: "me")
        design.members.append(Person(id: "u2", name: "Alex"))
        await spotlight.update([design, hidden], me: "me")
        #expect(indexed == [["Design team"], ["Design studio"], ["Design studio"]])   // the hidden one never
    }
    @Test func membersAreKeywords() {
        let room = Conversation(id: "space/a", name: "Design team", kind: .space, members: [Person(id: "u1", name: "Maria Chen"), Person(id: "u2", name: "Alex")])
        #expect(ConversationEntity(room).keywords == ["Maria Chen", "Alex"])
    }
}
