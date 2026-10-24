import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// People as Shortcuts and Siri see them: the ones in my conversations first, each once, never me.
struct PersonEntityTests {
    @Test func knownPeopleMatchByNameOrEmailOnceEach() {
        let me = Person(id: "me", name: "Dave")
        let maria = Person(id: "u1", name: "Maria Chen", email: "maria@example.com")
        let alex = Person(id: "u2", name: "Alex Rivera")
        let rooms = [
            Conversation.fixture("space/a", members: [me, maria, alex]),
            Conversation.fixture("dm/b", kind: .direct, name: "Maria Chen", members: [me, maria]),
        ]
        #expect(PersonEntity.known(in: rooms, me: "me").map(\.id) == ["u1", "u2"])
        #expect(PersonEntity.known(matching: "maria@", in: rooms, me: "me").map(\.id) == ["u1"])
        #expect(PersonEntity.known(matching: "rivera", in: rooms, me: "me").map(\.id) == ["u2"])
        #expect(PersonEntity.known(matching: "dave", in: rooms, me: "me").isEmpty)
    }
}
