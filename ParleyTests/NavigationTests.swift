import Testing
@testable import Parley

struct NavigationTests {
    private let rooms = [
        Conversation(id: "s1", name: "Space", kind: .space, members: [], unread: 2),
        Conversation(id: "d1", name: "Ann", kind: .direct, members: []),
        Conversation(id: "p1", name: "Pinned", kind: .group, members: [], pinned: true),
        Conversation(id: "d2", name: "Bo", kind: .direct, members: [], unread: 1),
    ]
    @Test func sidebarOrderIsPinnedThenDirectThenSpaces() {
        #expect(Conversation.sidebarOrder(rooms).map(\.id) == ["p1", "d1", "d2", "s1"])
    }
    @Test func commandNumbersPickBySidebarPosition() {
        #expect(Conversation.atShortcut(1, in: rooms)?.id == "p1")
        #expect(Conversation.atShortcut(4, in: rooms)?.id == "s1")
        #expect(Conversation.atShortcut(9, in: rooms) == nil)
    }
    @Test func nextUnreadWrapsInSidebarOrder() {
        #expect(Conversation.nextUnread(after: "p1", in: rooms, forward: true)?.id == "d2")
        #expect(Conversation.nextUnread(after: "d2", in: rooms, forward: true)?.id == "s1")
        #expect(Conversation.nextUnread(after: "s1", in: rooms, forward: true)?.id == "d2")   // wraps
        #expect(Conversation.nextUnread(after: "s1", in: rooms, forward: false)?.id == "d2")
        #expect(Conversation.nextUnread(after: nil, in: rooms, forward: true)?.id == "d2")
        #expect(Conversation.nextUnread(after: "p1", in: rooms.map { var r = $0; r.unread = 0; return r }, forward: true) == nil)
    }
}

struct SidebarSectionTests {
    private let rooms = [
        Conversation(id: "s1", name: "Space", kind: .space, members: []),
        Conversation(id: "ps", name: "Pinned space", kind: .space, members: [], pinned: true),
        Conversation(id: "d1", name: "Ann", kind: .direct, members: []),
        Conversation(id: "pd", name: "Pinned DM", kind: .direct, members: [], unread: 3, pinned: true),
    ]
    /// Pinned DMs and spaces share one section, in server order, and don't repeat below.
    @Test func pinnedSectionHoldsDMsAndSpacesOnce() {
        let sections = Conversation.sidebarSections(rooms)
        #expect(sections.map(\.title) == ["Shortcuts", "Pinned", "Direct messages", "Spaces", "Apps"])
        #expect(sections.map { $0.rooms.map(\.id) } == [[], ["ps", "pd"], ["d1"], ["s1"], []])
        #expect(Conversation.sidebarOrder(rooms).map(\.id) == ["ps", "pd", "d1", "s1"])
    }
    /// As web Chat: Ask Gemini on top as a shortcut, app DMs in their own section after spaces; a pinned app stays pinned.
    @Test func appDMsHaveTheirOwnSections() {
        let apps = rooms + [
            Conversation(id: "a1", name: "Google Drive", kind: .direct, members: [], app: .bot),
            Conversation(id: "pa", name: "Pinned app", kind: .direct, members: [], pinned: true, app: .bot),
            Conversation(id: "g", name: "Ask Gemini", kind: .direct, members: [], app: .gemini),
        ]
        let sections = Conversation.sidebarSections(apps)
        #expect(sections.map(\.title) == ["Shortcuts", "Pinned", "Direct messages", "Spaces", "Apps"])
        #expect(sections.map { $0.rooms.map(\.id) } == [["g"], ["ps", "pd", "pa"], ["d1"], ["s1"], ["a1"]])
    }
    @Test func shortcutsAndNextUnreadFollowThePinnedSection() {
        #expect(Conversation.atShortcut(1, in: rooms)?.id == "ps")
        #expect(Conversation.atShortcut(3, in: rooms)?.id == "d1")
        #expect(Conversation.nextUnread(after: "d1", in: rooms, forward: true)?.id == "pd")   // wraps to the pinned DM
    }
}

/// Settings ▸ Limit sidebar sections: long sections show their first rows and a "Show all" row, as web Chat.
struct SidebarLimitTests {
    private let dms = (1...15).map { Conversation(id: "d\($0)", name: "DM \($0)", kind: .direct, members: []) }
    private func section(_ title: String, _ rooms: [Conversation], limit: Int? = 10, expanded: Set<String> = [], selected: ConversationID? = nil)
        -> (rooms: [String], hidden: [String]) {
        let section = Conversation.sidebarSections(rooms, limit: limit, expanded: expanded, selected: selected).first { $0.title == title }!
        return (section.rooms.map(\.id), section.hidden.map(\.id))
    }
    @Test func aLongSectionShowsItsFirstRows() {
        let capped = section("Direct messages", dms)
        #expect(capped.rooms == (1...10).map { "d\($0)" })
        #expect(capped.hidden == (11...15).map { "d\($0)" })
    }
    @Test func offOrShortSectionsAreUnchanged() {
        #expect(section("Direct messages", dms, limit: nil).rooms.count == 15)
        #expect(section("Direct messages", dms, limit: nil).hidden.isEmpty)
        #expect(section("Direct messages", Array(dms.prefix(10))).hidden.isEmpty)
    }
    /// Unread conversations and the open one stay visible past the cap, in their place.
    @Test func unreadAndSelectedRowsAreNeverHidden() {
        var rooms = dms
        rooms[12].unread = 3
        let capped = section("Direct messages", rooms, selected: "d14")
        #expect(capped.rooms == (1...10).map { "d\($0)" } + ["d13", "d14"])
        #expect(capped.hidden == ["d11", "d12", "d15"])
    }
    /// "Show all" lists every row; what the cap would hide stays known, for "Show less".
    @Test func anExpandedSectionShowsEverything() {
        let open = section("Direct messages", dms, expanded: ["Direct messages"])
        #expect(open.rooms.count == 15)
        #expect(open.hidden.count == 5)
    }
    @Test func spacesAndAppsAreCappedButPinnedIsNot() {
        let spaces = (1...12).map { Conversation(id: "s\($0)", name: "S", kind: .space, members: []) }
        let apps = (1...12).map { Conversation(id: "a\($0)", name: "A", kind: .direct, members: [], app: .bot) }
        let pinned = (1...12).map { Conversation(id: "p\($0)", name: "P", kind: .group, members: [], pinned: true) }
        #expect(section("Spaces", spaces).rooms.count == 10)
        #expect(section("Apps", apps).rooms.count == 10)
        #expect(section("Pinned", pinned).rooms.count == 12)
    }
    /// ⌘ numbers count the rows shown; ⌥↓ still reaches every unread row, since the cap never hides one.
    @Test func shortcutsSkipHiddenRows() {
        let rooms = Array(dms.prefix(4)) + [Conversation(id: "s1", name: "S", kind: .space, members: [], unread: 1)]
        #expect(Conversation.atShortcut(3, in: rooms, limit: 2)?.id == "s1")
        #expect(Conversation.atShortcut(3, in: rooms)?.id == "d3")
        #expect(Conversation.nextUnread(after: "d1", in: rooms, forward: true)?.id == "s1")
    }
}
