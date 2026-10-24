import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    /// "Alice, Bob, and You" for a reaction pill's hover card, fetched once per reaction state; nil when the lookup failed.
    /// Keyed by the `Reaction` value, so a reaction that changes (people or count) is looked up again.
    func reactorsLine(_ reaction: Reaction, on message: MessageID) async -> String? {
        if lookups.reactors[message]?[reaction] == nil {
            guard let people = try? await backend.reactors(of: message, emoji: reaction.emoji, custom: reaction.custom)
            else { return nil }
            lookups.reactors[message, default: [:]][reaction] = people
        }
        let people = lookups.reactors[message]?[reaction] ?? []
        return Self.reactorsLine(names: people.map { $0.id == me.id ? "You" : $0.name }, count: reaction.people.count)
    }
    /// Others first, then "You", as Google Chat lists them; people the server left out are counted. No names yet: the count.
    static func reactorsLine(names: [String], count: Int) -> String {
        guard !names.isEmpty else { return count == 1 ? "1 person" : "\(count) people" }
        var list = names.filter { $0 != "You" } + names.filter { $0 == "You" }
        if count > names.count { list.append(count - names.count == 1 ? "1 other" : "\(count - names.count) others") }
        return ListFormatter.localizedString(byJoining: list)
    }
    func deleteMessage(_ message: Message) async {
        do { try await backend.deleteMessage(message.id) } catch { report(error) }
    }
    /// Siri's edit: one of my sent messages gets new plain text. False when it isn't mine or Google refused it.
    func editText(of id: MessageID, to text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let message = history.messages.first(where: { $0.id == id }), message.sender.id == me.id,
            message.delivery == .sent
        else { return false }
        do {
            try await backend.edit(id, text: text, formatting: [])
            return true
        } catch {
            log.error("edit failed: \(Redaction.redact(String(describing: error)), privacy: .public)")
            return false
        }
    }
    /// Siri's unsend: one of my sent messages is deleted for everyone. False when it isn't mine or Google refused it.
    func unsend(_ id: MessageID) async -> Bool {
        guard let message = history.messages.first(where: { $0.id == id }), message.sender.id == me.id,
            message.delivery == .sent
        else { return false }
        do {
            try await backend.deleteMessage(id)
            return true
        } catch {
            log.error("unsend failed: \(Redaction.redact(String(describing: error)), privacy: .public)")
            return false
        }
    }
    /// `custom`: a custom emoji picked for the reaction; a pill's own custom emoji goes back whole.
    func react(_ emoji: String, custom: CustomEmoji? = nil, to message: Message) async {
        let existing = message.reactions.first { $0.emoji == emoji }
        let present = !(existing?.people.contains(me.id) ?? false)
        do {
            try await backend.setReaction(emoji, custom: existing?.custom ?? custom, for: message.id, present: present)
        } catch { report(error, undone: "react") }
    }
    func loadPinned(_ conversation: ConversationID) async {
        do {
            let list = try await backend.boardMessages(in: conversation)
            rooms.pinned[conversation] = list
            let ids = Set(list.map(\.id))
            for index in history.messages.indices
            where history.messages[index].conversationID == conversation
                && history.messages[index].pinned != ids.contains(history.messages[index].id)
            {
                history.messages[index].pinned.toggle()
            }
        } catch { log.error("board not loaded: \(Redaction.redact(error.localizedDescription), privacy: .public)") }
    }
    func setBoardPinned(_ value: Bool, _ message: Message) async {
        func mark(_ value: Bool) {
            for index in history.messages.indices where history.messages[index].id == message.id {
                history.messages[index].pinned = value
            }
            guard var list = rooms.pinned[message.conversationID] else { return }
            list.removeAll { $0.id == message.id }
            if value {
                var added = message
                added.pinned = true
                list.insert(added, at: 0)
            }
            rooms.pinned[message.conversationID] = list
        }
        let undoable = Undoable(value ? "Pin to Board" : "Unpin from Board") {
            await self.setBoardPinned(!value, message)
        }
        await optimistically(.toast(value ? "pin the message" : "unpin the message"), undoable: undoable) {
            mark(value)
        } undo: {
            mark(!value)
        } send: {
            try await backend.setBoardPinned(value, for: message.id)
        }
    }
    /// Starred or unstarred everywhere it shows at once; a refusal puts it back and says why.
    func setStarred(_ starred: Bool, _ message: Message) async {
        func mark(_ value: Bool) {
            for index in history.messages.indices where history.messages[index].id == message.id {
                history.messages[index].starred = value
            }
            for (key, list) in history.shortcutLists {
                history.shortcutLists[key] = list.map {
                    var listed = $0
                    if listed.id == message.id { listed.starred = value }
                    return listed
                }
            }
            if value, let list = history.shortcutLists[.starred], !list.contains(where: { $0.id == message.id }) {
                var added = message
                added.starred = true
                history.shortcutLists[.starred] = (list + [added]).sorted { $0.createdAt > $1.createdAt }
            }
        }
        let undoable = Undoable(starred ? "Star" : "Unstar") { await self.setStarred(!starred, message) }
        await optimistically(.toast(starred ? "star the message" : "unstar the message"), undoable: undoable) {
            mark(starred)
        } undo: {
            mark(!starred)
        } send: {
            try await backend.setStarred(starred, for: message.id)
        }
        persist()
    }
}
