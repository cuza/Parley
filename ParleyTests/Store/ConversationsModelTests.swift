import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// The conversation lists on their own, without a store or a backend.
@MainActor struct ConversationsModelTests {
    private func room(_ id: String, hidden: Bool = false) -> Conversation {
        var room = Conversation.fixture(ConversationID(id), name: id)
        if hidden { room.hidden = Date(timeIntervalSince1970: 0) }
        return room
    }

    @Test func aListPutsTheHiddenApartAndTellsTheBadge() {
        let rooms = ConversationsModel()
        var changes = 0
        rooms.listsChanged = { changes += 1 }
        rooms.list([room("a"), room("b", hidden: true), room("c")], threads: [])
        #expect(rooms.conversations.map(\.id) == ["a", "c"] && rooms.hidden.map(\.id) == ["b"])
        #expect(changes == 2)  // the conversations and Home's threads
        rooms.remove("b")
        rooms.remove("a")
        #expect(rooms.conversations.map(\.id) == ["c"] && rooms.hidden.isEmpty)
    }
    @Test func invitationsAreAskedAgainAfterTheirTimeOrWhenForced() {
        let rooms = ConversationsModel()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(rooms.invitationsDue(at: start, ttl: 60, force: false))
        rooms.invitationsFetched = start
        #expect(!rooms.invitationsDue(at: start.addingTimeInterval(59), ttl: 60, force: false))
        #expect(rooms.invitationsDue(at: start.addingTimeInterval(59), ttl: 60, force: true))
        #expect(rooms.invitationsDue(at: start.addingTimeInterval(60), ttl: 60, force: false))
    }
}
