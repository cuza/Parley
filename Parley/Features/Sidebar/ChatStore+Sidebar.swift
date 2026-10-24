import Foundation
import ParleyDomain

extension ChatStore {
    func setSidebarPinned(_ pinned: Bool, _ id: ConversationID) async {
        await change(
            id, \.pinned, to: pinned,
            undoable: Undoable(pinned ? "Pin" : "Unpin") { await self.setSidebarPinned(!pinned, id) }
        ) {
            try await self.backend.setSidebarPinned(pinned, for: id)
        }
    }
    func setMuted(_ muted: Bool, _ id: ConversationID) async {
        await change(
            id, \.muted, to: muted, undoable: Undoable(muted ? "Mute" : "Unmute") { await self.setMuted(!muted, id) }
        ) {
            try await self.backend.setMuted(muted, for: id)
        }
    }
    func setNotificationLevel(_ level: NotificationLevel, _ id: ConversationID) async {
        guard let room = conversation(id) else { return }
        let undoable = room.notificationLevel.map { before in
            Undoable("Change Notifications") { await self.setNotificationLevel(before, id) }
        }
        await change(id, \.notificationLevel, to: level, undoable: undoable) {
            try await self.backend.setNotificationLevel(level, muted: room.muted, for: id)
        }
    }
    /// Shown at once and sent; a refusal puts back only this field (others may have changed meanwhile) and says why.
    func change<Value>(
        _ id: ConversationID, _ field: WritableKeyPath<Conversation, Value>, to value: Value,
        undoable: Undoable? = nil, send: () async throws -> Void
    ) async {
        guard let index = conversationIndex(id) else { return }
        let before = rooms.conversations[index][keyPath: field]
        await optimistically(.toast("change the conversation"), undoable: undoable) {
            rooms.conversations[index][keyPath: field] = value
            persist()
        } undo: {
            if let index = conversationIndex(id) { rooms.conversations[index][keyPath: field] = before }
            persist()
        } send: {
            try await send()
        }
    }
    func leave(_ id: ConversationID) async {
        await removeFromSidebar(id, refusal: .alert) { try await self.backend.leave(id) }
    }
    func hide(_ id: ConversationID) async {
        guard var room = conversation(id) else { return }
        await removeFromSidebar(
            id, refusal: .toast("hide the conversation"), undoable: Undoable("Hide") { await self.unhide(id) }
        ) {
            try await self.backend.setHidden(true, for: id)
        }
        guard !rooms.conversations.contains(where: { $0.id == id }), !rooms.hidden.contains(where: { $0.id == id })
        else { return }  // refused, or pushed meanwhile
        room.hidden = .now
        rooms.hidden.insert(room, at: 0)
    }
    /// Back in the sidebar at once; a refusal hides it again and says why.
    func unhide(_ id: ConversationID) async {
        guard var room = rooms.hidden.first(where: { $0.id == id }) else { return }
        let hiddenAt = room.hidden
        await optimistically(.toast("unhide the conversation"), undoable: Undoable("Unhide") { await self.hide(id) }) {
            room.hidden = nil
            apply(.conversationUpserted(room))
            persist()
        } undo: {
            room.hidden = hiddenAt
            apply(.conversationUpserted(room))
            persist()
        } send: {
            try await backend.setHidden(false, for: id)
        }
    }
    /// Gone from the sidebar at once; a refusal puts it back where it was.
    func removeFromSidebar(
        _ id: ConversationID, refusal: Refusal, undoable: Undoable? = nil, send: () async throws -> Void
    ) async {
        guard let index = conversationIndex(id) else { return }
        let room = rooms.conversations[index]
        await optimistically(refusal, undoable: undoable) {
            apply(.conversationRemoved(id))
        } undo: {
            if !rooms.conversations.contains(where: { $0.id == id }) {
                rooms.conversations.insert(room, at: min(index, rooms.conversations.count))
            }
            persist()
        } send: {
            try await send()
        }
    }
    /// A new section after my others, with `conversation` moved into it, as web Chat's Move to a new section.
    func createSection(_ name: String, moving conversation: ConversationID?) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let last = rooms.sections.filter { $0.kind == .custom || $0.kind == .spaces }.map(\.position).max() ?? 2
        do {
            let made = try await backend.createSection(named: name, at: last + 1)
            // Google moves the sections from that place down by one.
            rooms.sections =
                rooms.sections.map {
                    var section = $0
                    if section.position >= made.position { section.position += 1 }
                    return section
                } + [made]
            if let conversation { await moveConversation(conversation, to: made.key) }
        } catch { report(error) }
    }
    func renameSection(_ section: SidebarSection, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = rooms.sections.firstIndex(where: { $0.id == section.id }) else { return }
        let undoable = Undoable("Rename Section") {
            if let now = self.section(section.id) { await self.renameSection(now, to: section.name) }
        }
        await optimistically(.toast("rename the section"), undoable: undoable) {
            rooms.sections[index].name = name
        } undo: {
            rooms.sections[index].name = section.name
        } send: {
            try await backend.renameSection(section, to: name)
        }
    }
    /// One place up or down among the sections below Shortcuts; Google renumbers the rest, as here.
    func moveSection(_ section: SidebarSection, up: Bool) async {
        let ordered = rooms.sections.sorted { $0.position < $1.position }
        guard let index = ordered.firstIndex(where: { $0.id == section.id }),
            case let neighbour = up ? index - 1 : index + 1,
            ordered.indices.contains(neighbour), ordered[neighbour].kind != .shortcuts
        else { return }
        let before = rooms.sections
        let target = ordered[neighbour].position
        let undoable = Undoable(up ? "Move Section Up" : "Move Section Down") {
            if let now = self.section(section.id) { await self.moveSection(now, up: !up) }
        }
        await optimistically(.toast("move the section"), undoable: undoable) {
            rooms.sections = rooms.sections.map {
                var other = $0
                if other.id == section.id {
                    other.position = target
                } else if other.id == ordered[neighbour].id {
                    other.position = section.position
                }
                return other
            }
        } undo: {
            rooms.sections = before
        } send: {
            try await backend.moveSection(section, to: target)
        }
    }
    /// As it is now: an undo comes after its own change renamed or moved it.
    private func section(_ id: SidebarSection.ID) -> SidebarSection? { rooms.sections.first { $0.id == id } }
    /// Its conversations go back to their default sections, as Google Chat does.
    func deleteSection(_ section: SidebarSection) async {
        let before = (rooms.sections, rooms.conversations)
        await optimistically(.alert) {
            rooms.sections.removeAll { $0.id == section.id }
            for index in rooms.conversations.indices where rooms.conversations[index].section == section.key {
                rooms.conversations[index].section = nil
            }
        } undo: {
            (rooms.sections, rooms.conversations) = before
        } send: {
            try await backend.deleteSection(section)
        }
        persist()
    }
    /// Into one of my sections (its key), or back to its default one (nil).
    func moveConversation(_ id: ConversationID, to section: String?) async {
        let previous = conversation(id)?.section
        guard previous != section else { return }
        await change(id, \.section, to: section) {
            try await self.backend.moveConversation(id, to: section, from: previous)
        }
    }
    func loadBlocked() async {
        if let people = try? await backend.blockedPeople() { rooms.blockedPeople = Set(people) }
    }
    /// The 1:1 DM with someone, if the sidebar has one.
    func dm(with person: PersonID) -> Conversation? {
        rooms.conversations.first { $0.kind == .direct && $0.app == nil && partner(in: $0) == person }
    }
    /// Blocks a person, as Google Chat's Block and report: their DM leaves the sidebar at once; a refusal puts it back.
    func block(person: PersonID, report toGoogle: Bool) async {
        let dm = dm(with: person)
        await optimistically(.alert) {  // an alert: a block that fades unnoticed leaves the user exposed
            rooms.blockedPeople.insert(person)
            if let dm { apply(.conversationRemoved(dm.id)) }
        } undo: {
            rooms.blockedPeople.remove(person)
            if let dm, !rooms.conversations.contains(where: { $0.id == dm.id }) { rooms.conversations.append(dm) }
        } send: {
            try await backend.setPersonBlocked(true, for: person, dm: dm?.id, report: toGoogle)
        }
        persist()
    }
    func unblock(person: PersonID) async {
        await optimistically(.alert) {
            rooms.blockedPeople.remove(person)
        } undo: {
            rooms.blockedPeople.insert(person)
        } send: {
            try await backend.setPersonBlocked(false, for: person, dm: dm(with: person)?.id, report: false)
        }
        await loadBlocked()
    }
    func blockSpace(_ id: ConversationID, report toGoogle: Bool) async {
        await removeFromSidebar(id, refusal: .alert) {
            try await self.backend.setSpaceBlocked(true, for: id, report: toGoogle)
        }
    }
    func blockedSpaces() async throws -> [BlockedSpace] { try await backend.blockedSpaces() }
    func unblockSpace(_ id: ConversationID) async {
        do { try await backend.setSpaceBlocked(false, for: id, report: false) } catch { report(error) }
    }
    /// A blocked person's message as the timeline shows it: what they sent stays hidden, as Google Chat hides it.
    static func blockedView(_ message: Message) -> Message {
        var shown = message
        shown.text = "Message from a blocked person"
        shown.formatting = [TextStyleRange(style: .italic, start: 0, length: (shown.text as NSString).length)]
        shown.attachments = []
        shown.quote = nil
        return shown
    }
    /// Errors stay with the caller's sheet.
    func reportMessage(_ message: Message, reason: ReportReason, explanation: String) async throws {
        try await backend.reportMessage(message, reason: reason, explanation: explanation)
    }
}
