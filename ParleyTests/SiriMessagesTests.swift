import AppIntents
import AppKit
import Foundation
import Testing
@testable import Parley

/// Siri's messaging templates name people, not conversations: Parley finds the DM or group chat with exactly them.
@MainActor struct SiriMessagesTests {
    @Test func peopleNameTheirConversation() async throws {
        guard #available(macOS 27, *) else { return }
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let people = Dictionary(store.conversations.flatMap(\.members).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let alex = try #require(people["alex"]), maria = try #require(people["maria"])
        #expect(try await store.conversation(for: .messagePerson(SiriPerson(alex))).id == "alex")
        #expect(try await store.conversation(for: .messagePeople([SiriPerson(maria), SiriPerson(alex)])).id == "launch")   // the group DM
    }
    @Test func aConversationShowsItsPeopleAndState() throws {
        guard #available(macOS 27, *) else { return }
        let store = ChatStore(backend: FakeBackend())
        var room = Conversation(id: "space/a", name: "Design", kind: .space, members: [store.me, Person(id: "u1", name: "Maria")], unread: 2)
        room.muted = true
        let entity = SiriConversation(room, store: store)
        #expect(entity.recipients.map(\.id) == ["u1"] && !entity.isRead && entity.attributes == [.muted] && entity.conversationName == "Design")
    }
    /// Edit and unsend: only my own sent messages, through the server; someone else's is refused.
    @Test func editAndUnsendOnlyMine() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        let mine = try #require(store.messages.first { $0.id == "design/d3/d3" || ($0.conversationID == "design" && $0.sender.id == store.me.id && $0.threadID == nil) })
        let theirs = try #require(store.messages.first { $0.conversationID == "design" && $0.sender.id != store.me.id && !$0.isSystem })
        #expect(await store.editText(of: mine.id, to: "Agreed, compact sidebar first."))
        await eventually { store.messages.first { $0.id == mine.id }?.text == "Agreed, compact sidebar first." }   // the server's echo
        #expect(store.messages.first { $0.id == mine.id }?.text == "Agreed, compact sidebar first.")
        #expect(await store.editText(of: theirs.id, to: "Not mine") == false)
        #expect(await store.unsend(theirs.id) == false)
        #expect(await store.unsend(mine.id))
        await eventually { !store.messages.contains { $0.id == mine.id } }
        #expect(!store.messages.contains { $0.id == mine.id })
    }
    /// Each visible row names its message for Siri.
    @Test func rowsNameTheirMessages() throws {
        guard #available(macOS 27, *) else { return }
        let coordinator = MessageTable.Coordinator()
        let scroll = MessageTable.makeScrollView(coordinator, identifier: "t")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        let message = Message(id: "space/x/t/m", conversationID: "space/x", sender: Person(id: "u1", name: "Maria"), text: "Hi", createdAt: .now)
        coordinator.update(MessageTable(rows: TimelineRow.rows([message], seen: [:]), meID: "me", kind: .space, highlighted: nil, actions: MessageRowActions(),
                                        nearTop: {}, nearBottom: {}, detached: false, atBottomChanged: { _ in }, scrollRequest: 0, bottomInset: 0))
        let table = try #require(scroll.documentView as? NSTableView)
        #expect(table.appIntentsDataSource === coordinator)
        #expect(coordinator.tableView(table, appEntityIdentifierFor: 0) == EntityIdentifier(for: SiriMessage.self, identifier: "space/x/t/m"))
        #expect(coordinator.tableView(table, appEntityIdentifierFor: 3) == nil)
    }
    /// A contact from Contacts becomes a Google Chat person: by email, by name, then the directory; nobody, an error.
    @Test func contactsMatchGoogleChatPeople() async throws {
        guard #available(macOS 27, *) else { return }
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let known = PersonEntity.known(in: store.conversations, me: store.me.id)
        func contact(_ name: String, email: String? = nil) -> IntentPerson {
            IntentPerson(identifier: .contact(UUID().uuidString), name: .displayName(name), handle: email.map { IntentPerson.Handle(emailAddress: $0) })
        }
        #expect(try await store.chatPerson(for: contact("maria chen"), known: known).id == "maria")          // by name, any case
        #expect(try await store.chatPerson(for: contact("P. Patel", email: "priya@example.com"), known: known).id == "priya")   // the directory
        await #expect(throws: ParleyIntentError.self) { try await store.chatPerson(for: contact("Nobody Here"), known: known) }
        #expect(try await store.conversation(for: .people([contact("Alex Rivera")])).id == "alex")
    }
    /// A space named to Siri is a recipient that sends to the space itself.
    @Test func aSpaceIsARecipient() async throws {
        guard #available(macOS 27, *) else { return }
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let space = try #require(store.conversations.first { $0.id == "general" })
        let recipient = SiriPerson(recipient: space)
        #expect(SiriPerson.recipients(store.conversations).contains { $0.id == "general" })
        #expect(!SiriPerson.recipients(store.conversations).contains { $0.id == "alex" })   // a DM is its person
        #expect(try await store.conversation(for: .messagePerson(recipient)).id == "general")
    }
    /// A send is donated with the recipient Siri would name: the person of a 1:1 DM, else the space itself.
    @Test func donationsNameTheRecipient() throws {
        guard #available(macOS 27, *) else { return }
        let maria = Person(id: "u1", name: "Maria")
        let dm = Conversation(id: "dm/a", name: "Maria", kind: .direct, members: [Person(id: "me", name: "Me"), maria])
        let space = Conversation(id: "space/b", name: "Design", kind: .space, members: [maria])
        guard case .messagePerson(let person) = SiriDonation.destination(for: dm, me: "me"), case .messagePerson(let room) = SiriDonation.destination(for: space, me: "me") else {
            Issue.record("expected one recipient each"); return
        }
        #expect(person.id == "u1" && room.id == "space/b")
    }
}
