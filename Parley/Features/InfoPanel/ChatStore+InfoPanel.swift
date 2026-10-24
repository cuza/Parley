import Foundation
import ParleyDomain

extension ChatStore {
    /// ⌘I or the title: opens the info panel in place of a thread, or closes it.
    func toggleInfo(window: ConversationID? = nil) {
        navigation.setPane(window) { $0.toggleInfo() }  // over a person's details, it goes back to the info panel
    }
    /// Everyone in the conversation, me included: the full list once `loadMembers` has it, else the members it came with.
    func roster(_ conversation: Conversation) -> [Person] {
        rooms.members[conversation.id] ?? conversation.members
    }
    /// Where `shared` and `sharedMore` keep a conversation's tab.
    func sharedKey(_ conversation: ConversationID, _ category: SharedCategory) -> String {
        "\(conversation)/\(category.rawValue)"
    }
    /// The first page of a tab when it first shows, or the next page. A failure keeps the panel on loaded messages.
    func loadShared(_ category: SharedCategory, in conversation: ConversationID, more: Bool = false) async {
        let key = sharedKey(conversation, category)
        guard more ? rooms.sharedMore.contains(key) : rooms.shared[key] == nil else { return }
        rooms.sharedMore.remove(key)  // one request at a time
        do {
            let page = try await backend.shared(category, in: conversation, after: more ? rooms.shared[key]?.last : nil)
            var items = rooms.shared[key] ?? []
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            rooms.shared[key] = items
            if page.hasMore { rooms.sharedMore.insert(key) }
        } catch is CancellationError {
            if more { rooms.sharedMore.insert(key) }
        } catch {
            if (error as? AuthFailure)?.endsSession == true { report(error) }
            if more { rooms.sharedMore.insert(key) }
        }
    }
    /// Fetches a conversation's members once per launch; a failure keeps the fallback and allows a later retry.
    func loadMembers(_ conversation: ConversationID) async {
        guard rooms.members[conversation] == nil else { return }
        await reloadMembers(conversation)
    }
    /// The list on screen stays until the new one arrives.
    func reloadMembers(_ conversation: ConversationID) async {
        guard !rooms.memberLoads.contains(conversation) else { return }
        rooms.memberLoads.insert(conversation)
        defer { rooms.memberLoads.remove(conversation) }
        if let people = try? await backend.members(of: conversation), !people.isEmpty {
            rooms.members[conversation] = people
            rooms.roles[conversation] = await backend.roles(in: conversation)
        }
    }
    /// Unknown (nothing offered) when the server doesn't answer.
    func loadPermissions(_ conversation: ConversationID) async {
        guard self.conversation(conversation)?.kind != .direct else { return }
        if let allowed = try? await backend.permissions(in: conversation) { rooms.permissions[conversation] = allowed }
    }
    func rename(_ id: ConversationID, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let room = conversation(id), room.name != name else { return }
        await change(id, \.name, to: name) { try await self.backend.updateProfile(id, name: name, emoji: nil) }
    }
    /// Description and guidelines go together, as Google Chat saves them; empty clears one.
    func updateDetails(_ id: ConversationID, description: String, guidelines: String) async {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let details = (
            trim(description).isEmpty ? nil : trim(description), trim(guidelines).isEmpty ? nil : trim(guidelines)
        )
        guard let index = conversationIndex(id),
            (rooms.conversations[index].description, rooms.conversations[index].guidelines) != details
        else { return }
        let before = (rooms.conversations[index].description, rooms.conversations[index].guidelines)
        await optimistically(.alert) {  // an alert: what was typed is gone
            rooms.conversations[index].description = details.0
            rooms.conversations[index].guidelines = details.1
            persist()
        } undo: {
            if let index = conversationIndex(id) {
                (rooms.conversations[index].description, rooms.conversations[index].guidelines) = before
            }
            persist()
        } send: {
            try await backend.updateDetails(id, description: details.0 ?? "", guidelines: details.1 ?? "")
        }
    }
    func setHistory(_ on: Bool, for id: ConversationID) async {
        await change(id, \.historyOff, to: !on) { try await self.backend.setHistory(on, for: id) }
    }
    func setRole(_ role: MemberRole, for person: PersonID, in id: ConversationID) async {
        let before = rooms.roles[id]?[person]
        // Taking a role away that Google kept leaves them its access: an alert, so the user can act.
        let removesAccess = (before == .owner && role != .owner) || (before == .manager && role == .member)
        await optimistically(removesAccess ? .alert : .toast("change the role")) {
            rooms.roles[id, default: [:]][person] = role
        } undo: {
            rooms.roles[id]?[person] = before
        } send: {
            try await backend.setRole(role, for: person, in: id)
        }
    }
    func setEmoji(_ emoji: String, _ id: ConversationID) async {
        await change(id, \.emoji, to: emoji) { try await self.backend.updateProfile(id, name: nil, emoji: emoji) }
    }
    /// The roster is read again afterwards: a space lists invited people only once they join.
    func addMembers(_ people: [Person], to id: ConversationID) async {
        guard !people.isEmpty else { return }
        do { try await backend.addMembers(people.map(\.id), to: id) } catch {
            report(error)
            return
        }
        await reloadMembers(id)
    }
    /// Off the roster at once; a refusal puts them back.
    func removeMember(_ person: PersonID, from id: ConversationID) async {
        let before = rooms.members[id]
        await optimistically(.alert) {
            rooms.members[id]?.removeAll { $0.id == person }
        } undo: {
            rooms.members[id] = before
        } send: {
            try await backend.removeMember(person, from: id)
        }
    }
}
