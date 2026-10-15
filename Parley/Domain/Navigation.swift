import Foundation

/// Keyboard navigation over the sidebar (⌘1…9, ⌥⌘↑/⌥⌘↓ next unread).
extension Conversation {
    /// The sidebar's sections, as web Chat: Ask Gemini, pinned DMs and spaces together, direct messages and groups, spaces,
    /// then DMs with apps; each in server order.
    /// With a `limit` (Settings ▸ Limit sidebar sections), Direct messages, Spaces and Apps show their first `limit` rows,
    /// plus any unread or `selected` one past them in its place; `hidden` is what the cap leaves out, still reported for a
    /// section the user `expanded` ("Show all") so it can offer "Show less".
    /// `custom`: the sidebar's sections from the server; my own ones take their conversations out of the default ones, and
    /// all of them follow my order, after Shortcuts and Pinned.
    static func sidebarSections(_ rooms: [Conversation], limit: Int? = nil, expanded: Set<String> = [], selected: ConversationID? = nil,
                                custom: [SidebarSection] = [])
        -> [(title: String, rooms: [Conversation], hidden: [Conversation])] {
        let mine = custom.filter { $0.kind == .custom }, keys = Set(mine.map(\.key))
        let rest = rooms.filter { $0.app != .gemini }
        let unsorted = rest.filter { !$0.pinned && !($0.section.map(keys.contains) ?? false) }
        func position(_ kind: SidebarSection.Kind, _ fallback: Int) -> Int { custom.first { $0.kind == kind }?.position ?? fallback }
        let ordered: [(position: Int, title: String, rooms: [Conversation])] = ([
            (position(.directMessages, 1), "Direct messages", unsorted.filter { $0.kind != .space && $0.app == nil }),
            (position(.spaces, 2), "Spaces", unsorted.filter { $0.kind == .space }),
            (position(.apps, 4), "Apps", unsorted.filter { $0.app != nil }),
        ] + mine.map { section in (section.position, section.name, rest.filter { !$0.pinned && $0.section == section.key }) })
            .sorted { $0.position < $1.position }
        let sections = [("Shortcuts", rooms.filter { $0.app == .gemini }), ("Pinned", rest.filter(\.pinned))] + ordered.map { ($0.title, $0.rooms) }
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
    static func sidebarOrder(_ rooms: [Conversation], limit: Int? = nil, expanded: Set<String> = [], selected: ConversationID? = nil,
                             custom: [SidebarSection] = []) -> [Conversation] {
        sidebarSections(rooms, limit: limit, expanded: expanded, selected: selected, custom: custom).flatMap(\.rooms)
    }
    /// ⌘`number` (1-based) opens the conversation at that sidebar position.
    static func atShortcut(_ number: Int, in rooms: [Conversation], limit: Int? = nil, expanded: Set<String> = [], selected: ConversationID? = nil,
                           custom: [SidebarSection] = []) -> Conversation? {
        let order = sidebarOrder(rooms, limit: limit, expanded: expanded, selected: selected, custom: custom)
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
