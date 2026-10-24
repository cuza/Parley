import AppIntents
import ParleyDomain

/// Who Siri's send or draft goes to. Apple's template takes people only, so a space or group chat comes as a person
/// standing for it (`SiriPerson(recipient:)`), and the send goes to the conversation itself.
@available(macOS 27, *)
@UnionValue
enum SiriDestination {
    case people([IntentPerson])  // from Contacts: matched to Google Chat people by email, then by name
    case messagePerson(SiriPerson)
    case messagePeople([SiriPerson])
}

@available(macOS 27, *)
extension ChatStore {
    /// The conversation a Siri destination names: the DM or group chat with exactly those people, found or started.
    func conversation(for destination: SiriDestination) async throws -> Conversation {
        await listed()
        // A space or group chat named as a recipient is that conversation.
        let named: [SiriPerson] =
            switch destination {
            case .messagePerson(let person): [person]
            case .messagePeople(let people): people
            case .people: []
            }
        if named.count == 1, let room = rooms.conversations.first(where: { $0.id.rawValue == named[0].id }) {
            return room
        }
        let known = PersonEntity.known(in: rooms.conversations, me: me.id)
        let people: [Person]
        switch destination {
        case .messagePerson(let person):
            people = [known.first { $0.id.rawValue == person.id } ?? Person(id: PersonID(person.id), name: person.name)]
        case .messagePeople(let entities):
            people = entities.map { entity in
                known.first { $0.id.rawValue == entity.id } ?? Person(id: PersonID(entity.id), name: entity.name)
            }
        case .people(let contacts):
            var found: [Person] = []
            for contact in contacts { found.append(try await chatPerson(for: contact, known: known)) }
            people = found
        }
        try await message(people)
        if let id = navigation.selectedID, let room = rooms.conversations.first(where: { $0.id == id }) { return room }
        throw ParleyIntentError.failed("Parley can't find that conversation.")
    }
    /// A contact as a Google Chat person: by email among people I chat with, then by name, then Google Chat's directory.
    func chatPerson(for contact: IntentPerson, known: [Person]) async throws -> Person {
        var email: String?
        if case .emailAddress(let address)? = contact.handle?.value { email = address }
        let name: String? =
            switch contact.name {
            case .displayName(let name): name
            case .components(let parts): PersonNameComponentsFormatter().string(from: parts)
            default: nil
            }
        if let email, let person = known.first(where: { $0.email?.caseInsensitiveCompare(email) == .orderedSame }) {
            return person
        }
        if let name, let person = known.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        {
            return person
        }
        for query in [email, name].compactMap({ $0 }) {
            if let person = try? await searchPeople(matching: query).first(where: { $0.id != me.id }) { return person }
        }
        throw ParleyIntentError.failed("Parley can't find \(name ?? email ?? "that person") in Google Chat.")
    }
}
