import Foundation
import ParleyDomain

extension ChatStore {
    /// `person`'s detailed view in the side pane, as Google Chat opens it from their card.
    func showDetails(_ person: Person, window: ConversationID? = nil) {
        navigation.setPane(window) { $0.showPerson(person) }
    }
    /// What `person`'s detailed view shows; nil when Google Contacts answers none of it. Asked each time it opens, as
    /// what we shared changes.
    func personDetails(of person: Person) async -> PersonDetails? {
        try? await backend.personDetails(id: person.id, email: person.email)
    }
    /// The other person in a 1:1 DM, whose presence the sidebar and header show.
    func partner(in conversation: Conversation) -> PersonID? {
        conversation.kind == .direct ? conversation.members.first { $0.id != me.id }?.id : nil
    }
    func name(of person: PersonID, in conversation: ConversationID) -> String {
        let known = (rooms.members[conversation] ?? []) + (self.conversation(conversation)?.members ?? [])
        return (known.first { $0.id == person } ?? history.messages.first { $0.sender.id == person }?.sender)
            .map(\.name).flatMap { $0 == "Unknown" ? nil : $0 } ?? "Someone"
    }
    /// Who `id` is, as far as the conversation knows: its members, then the senders of loaded messages.
    func person(_ id: PersonID, in conversation: ConversationID) -> Person? {
        let known = (rooms.members[conversation] ?? []) + (self.conversation(conversation)?.members ?? [])
        return known.first { $0.id == id && $0.name != "Unknown" }
            ?? history.messages.first { $0.sender.id == id }?.sender
    }
    /// Whether `person` is from outside my organisation, as Google Chat marks them "External" in a member list.
    func isExternal(_ person: Person) -> Bool {
        var mine = me
        if mine.organization == nil {
            mine.organization = rooms.members.values.lazy.flatMap { $0 }.first { $0.id == mine.id }?.organization
        }
        return Self.external(person, to: mine)
    }
    /// As Google Chat decides it: someone whose organisation isn't mine. To a personal account nobody is; someone whose
    /// organisation isn't known isn't called external.
    nonisolated static func external(_ person: Person, to me: Person) -> Bool {
        guard person.id != me.id, let theirs = person.organization, let mine = me.organization, mine != .consumer else {
            return false
        }
        return theirs != mine
    }
    /// What `person`'s card adds to their name, as Google Chat's shows it: their job title from Google Contacts, and the
    /// time zone they share from Google Calendar for their local time. Asked once per session per person; empty for me
    /// or without an email, and a part they don't share is nil.
    func cardDetails(of person: Person) async -> PersonCardDetails {
        guard person.id != me.id, let email = person.email, !email.isEmpty else { return PersonCardDetails() }
        if let asked = lookups.personCards[email] { return await asked.value }
        let asking = Task { [backend] in
            async let title = try? backend.jobTitle(email: email, name: person.name)
            async let zone = try? backend.timeZone(email: email)
            return await PersonCardDetails(title: title ?? nil, timeZone: zone ?? nil)
        }
        lookups.personCards[email] = asking
        return await asking.value
    }
    /// A person's name from anything loaded: conversations, member lists, messages.
    func anyName(of person: PersonID) -> String {
        let known =
            rooms.conversations.flatMap(\.members) + rooms.members.values.flatMap { $0 }
            + history.messages.map(\.sender)
        return known.first { $0.id == person && $0.name != "Unknown" }?.name ?? "Someone"
    }
}
