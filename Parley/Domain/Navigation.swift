import Foundation

/// Keyboard navigation over the sidebar (⌘1…9, ⌥↑/⌥↓ next unread).
extension Conversation {
    /// The sidebar's sections, as web Chat: Ask Gemini, pinned DMs and spaces together, direct messages and groups, spaces,
    /// then DMs with apps; each in server order.
    /// With a `limit` (Settings ▸ Limit sidebar sections), Direct messages, Spaces and Apps show their first `limit` rows,
    /// plus any unread or `selected` one past them in its place; `hidden` is what the cap leaves out, still reported for a
    /// section the user `expanded` ("Show all") so it can offer "Show less".
    static func sidebarSections(_ rooms: [Conversation], limit: Int? = nil, expanded: Set<String> = [], selected: ConversationID? = nil)
        -> [(title: String, rooms: [Conversation], hidden: [Conversation])] {
        let rest = rooms.filter { $0.app != .gemini }
        let sections = [("Shortcuts", rooms.filter { $0.app == .gemini }), ("Pinned", rest.filter(\.pinned)),
                        ("Direct messages", rest.filter { !$0.pinned && $0.kind != .space && $0.app == nil }),
                        ("Spaces", rest.filter { !$0.pinned && $0.kind == .space }), ("Apps", rest.filter { !$0.pinned && $0.app != nil })]
        return sections.map { title, list in
            guard let limit, SidebarLimit.sections.contains(title), list.count > limit else { return (title, list, []) }
            var shown: [Conversation] = [], hidden: [Conversation] = []
            for (index, room) in list.enumerated() {
                if index < limit || room.unread > 0 || room.id == selected { shown.append(room) } else { hidden.append(room) }
            }
            return (title, expanded.contains(title) ? list : shown, hidden)
        }
    }
    /// The sidebar's order, top to bottom: the rows it shows.
    static func sidebarOrder(_ rooms: [Conversation], limit: Int? = nil, expanded: Set<String> = [], selected: ConversationID? = nil) -> [Conversation] {
        sidebarSections(rooms, limit: limit, expanded: expanded, selected: selected).flatMap(\.rooms)
    }
    /// ⌘`number` (1-based) opens the conversation at that sidebar position.
    static func atShortcut(_ number: Int, in rooms: [Conversation], limit: Int? = nil, expanded: Set<String> = [], selected: ConversationID? = nil) -> Conversation? {
        let order = sidebarOrder(rooms, limit: limit, expanded: expanded, selected: selected)
        return order.indices.contains(number - 1) ? order[number - 1] : nil
    }
    /// The next (or previous) conversation with unread messages after `current`, wrapping around the sidebar. Limit sidebar
    /// sections never hides an unread row, so this walks every row.
    static func nextUnread(after current: ConversationID?, in rooms: [Conversation], forward: Bool) -> Conversation? {
        let order = sidebarOrder(rooms)
        guard !order.isEmpty else { return nil }
        let start = current.flatMap { id in order.firstIndex { $0.id == id } } ?? (forward ? order.count - 1 : 0)
        for step in 1...order.count {
            let index = (start + (forward ? step : -step) % order.count + order.count) % order.count
            if order[index].unread > 0 && order[index].id != current { return order[index] }
        }
        return nil
    }
}

/// Settings ▸ Limit sidebar sections: as web Chat, long sections show their first rows and a "Show all" row.
enum SidebarLimit {
    static let enabledKey = "limitSidebarSections", countKey = "sidebarSectionLimit", expandedKey = "expandedSidebarSections"
    static let choices = [5, 10, 20]
    static let sections: Set<String> = ["Direct messages", "Spaces", "Apps"]
}
