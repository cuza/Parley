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
    public static func sidebarSections(
        _ rooms: [Conversation], limit: Int? = nil, expanded: Set<SidebarKey> = [], selected: ConversationID? = nil,
        custom: [SidebarSection] = []
    ) -> [SidebarRows] {
        let mine = custom.filter { $0.kind == .custom }
        let keys = Set(mine.map(\.key))
        let rest = rooms.filter { $0.app != .gemini }
        let unsorted = rest.filter { !$0.pinned && !($0.section.map(keys.contains) ?? false) }
        func position(_ kind: SidebarSection.Kind, _ fallback: Int) -> Int {
            custom.first { $0.kind == kind }?.position ?? fallback
        }
        let ordered: [(position: Int, rows: SidebarRows)] =
            ([
                (
                    position(.directMessages, 1),
                    SidebarRows(.directMessages, unsorted.filter { $0.kind != .space && $0.app == nil })
                ),
                (position(.spaces, 2), SidebarRows(.spaces, unsorted.filter { $0.kind == .space })),
                (position(.apps, 4), SidebarRows(.apps, unsorted.filter { $0.app != nil })),
            ]
            + mine.map { section in
                (
                    section.position,
                    SidebarRows(
                        .custom(section.key), title: section.name,
                        rest.filter { !$0.pinned && $0.section == section.key })
                )
            })
            .sorted { $0.position < $1.position }
        let sections =
            [SidebarRows(.shortcuts, rooms.filter { $0.app == .gemini }), SidebarRows(.pinned, rest.filter(\.pinned))]
            + ordered.map(\.rows)
        return sections.map { section in
            guard let limit, SidebarLimit.sections.contains(section.key), section.rooms.count > limit else {
                return section
            }
            var capped = section
            var shown: [Conversation] = []
            for (index, room) in section.rooms.enumerated() {
                if index < limit || room.unread > 0 || room.id == selected {
                    shown.append(room)
                } else {
                    capped.hidden.append(room)
                }
            }
            if !expanded.contains(section.key) { capped.rooms = shown }
            return capped
        }
    }
    /// The sidebar's order, top to bottom: the rows it shows.
    static func sidebarOrder(
        _ rooms: [Conversation], limit: Int? = nil, expanded: Set<SidebarKey> = [], selected: ConversationID? = nil,
        custom: [SidebarSection] = []
    ) -> [Conversation] {
        sidebarSections(rooms, limit: limit, expanded: expanded, selected: selected, custom: custom).flatMap(\.rooms)
    }
    /// ⌘`number` (1-based) opens the conversation at that sidebar position.
    public static func atShortcut(
        _ number: Int, in rooms: [Conversation], limit: Int? = nil, expanded: Set<SidebarKey> = [],
        selected: ConversationID? = nil,
        custom: [SidebarSection] = []
    ) -> Conversation? {
        let order = sidebarOrder(rooms, limit: limit, expanded: expanded, selected: selected, custom: custom)
        return order.indices.contains(number - 1) ? order[number - 1] : nil
    }
    /// The next (or previous) conversation with unread messages after `current`, wrapping around the sidebar. Limit sidebar
    /// sections never hides an unread row, so this walks every row.
    public static func nextUnread(after current: ConversationID?, in rooms: [Conversation], forward: Bool)
        -> Conversation?
    {
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

/// Which sidebar section, apart from the title it shows: a built-in one, or one of mine by its key
/// (`SidebarSection.key`), so two sections with the same name stay apart.
public enum SidebarKey: Hashable, Sendable {
    case shortcuts, pinned, directMessages, spaces, apps
    case custom(String)
    private static let builtIn: [SidebarKey] = [.shortcuts, .pinned, .directMessages, .spaces, .apps]
    /// A built-in section's title, which settings also store it by; a custom section's is its name, so empty here.
    public var title: String {
        switch self {
        case .shortcuts: "Shortcuts"
        case .pinned: "Pinned"
        case .directMessages: "Direct messages"
        case .spaces: "Spaces"
        case .apps: "Apps"
        case .custom: ""
        }
    }
    /// The built-in section stored by `title`.
    public init?(title: String) {
        guard let key = Self.builtIn.first(where: { $0.title == title }) else { return nil }
        self = key
    }
}

/// One sidebar section as it lays out: its rows, and the ones Limit sidebar sections leaves out.
public struct SidebarRows {
    public let key: SidebarKey
    public let title: String
    public var rooms: [Conversation]
    public var hidden: [Conversation] = []
    /// A built-in section shows its own title; one of mine passes its name.
    init(_ key: SidebarKey, title: String? = nil, _ rooms: [Conversation]) {
        self.key = key
        self.title = title ?? key.title
        self.rooms = rooms
    }
}

/// Settings ▸ Limit sidebar sections: as web Chat, long sections show their first rows and a "Show all" row.
public enum SidebarLimit {
    public static let enabledKey = "limitSidebarSections", countKey = "sidebarSectionLimit",
        expandedKey = "expandedSidebarSections"
    public static let choices = [5, 10, 20]
    public static let sections: Set<SidebarKey> = [.directMessages, .spaces, .apps]
}
