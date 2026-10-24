import Testing

@testable import Parley
@testable import ParleyDomain

struct NavigationTests {
    private let rooms = [
        Conversation.fixture("s1", name: "Space", unread: 2),
        Conversation.fixture("d1", kind: .direct, name: "Ann"),
        Conversation.fixture("p1", kind: .group, name: "Pinned", pinned: true),
        Conversation.fixture("d2", kind: .direct, name: "Bo", unread: 1),
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
        #expect(Conversation.nextUnread(after: "s1", in: rooms, forward: true)?.id == "d2")  // wraps
        #expect(Conversation.nextUnread(after: "s1", in: rooms, forward: false)?.id == "d2")
        #expect(Conversation.nextUnread(after: nil, in: rooms, forward: true)?.id == "d2")
        #expect(
            Conversation.nextUnread(
                after: "p1",
                in: rooms.map {
                    var room = $0
                    room.unread = 0
                    return room
                }, forward: true) == nil)
    }
}

struct SidebarSectionTests {
    private let rooms = [
        Conversation.fixture("s1", name: "Space"),
        Conversation.fixture("ps", name: "Pinned space", pinned: true),
        Conversation.fixture("d1", kind: .direct, name: "Ann"),
        Conversation.fixture("pd", kind: .direct, name: "Pinned DM", unread: 3, pinned: true),
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
        let apps =
            rooms + [
                Conversation.fixture("a1", kind: .direct, name: "Google Drive", app: .bot),
                Conversation.fixture("pa", kind: .direct, name: "Pinned app", pinned: true, app: .bot),
                Conversation.fixture("g", kind: .direct, name: "Ask Gemini", app: .gemini),
            ]
        let sections = Conversation.sidebarSections(apps)
        #expect(sections.map(\.title) == ["Shortcuts", "Pinned", "Direct messages", "Spaces", "Apps"])
        #expect(sections.map { $0.rooms.map(\.id) } == [["g"], ["ps", "pd", "pa"], ["d1"], ["s1"], ["a1"]])
    }
    @Test func shortcutsAndNextUnreadFollowThePinnedSection() {
        #expect(Conversation.atShortcut(1, in: rooms)?.id == "ps")
        #expect(Conversation.atShortcut(3, in: rooms)?.id == "d1")
        #expect(Conversation.nextUnread(after: "d1", in: rooms, forward: true)?.id == "pd")  // wraps to the pinned DM
    }
}

/// Settings ▸ Limit sidebar sections: long sections show their first rows and a "Show all" row, as web Chat.
struct SidebarLimitTests {
    private let dms = (1...15).map { Conversation.fixture("d\($0)", kind: .direct, name: "DM \($0)") }
    private func section(
        _ title: String, _ rooms: [Conversation], limit: Int? = 10, expanded: Set<SidebarKey> = [],
        selected: ConversationID? = nil
    )
        -> (rooms: [ConversationID], hidden: [ConversationID])
    {
        let section = Conversation.sidebarSections(rooms, limit: limit, expanded: expanded, selected: selected).first {
            $0.title == title
        }!
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
        let open = section("Direct messages", dms, expanded: [.directMessages])
        #expect(open.rooms.count == 15)
        #expect(open.hidden.count == 5)
    }
    @Test func spacesAndAppsAreCappedButPinnedIsNot() {
        let spaces = (1...12).map { Conversation.fixture("s\($0)", name: "S") }
        let apps = (1...12).map { Conversation.fixture("a\($0)", kind: .direct, name: "A", app: .bot) }
        let pinned = (1...12).map { Conversation.fixture("p\($0)", kind: .group, name: "P", pinned: true) }
        #expect(section("Spaces", spaces).rooms.count == 10)
        #expect(section("Apps", apps).rooms.count == 10)
        #expect(section("Pinned", pinned).rooms.count == 12)
    }
    /// ⌘ numbers count the rows shown; ⌥↓ still reaches every unread row, since the cap never hides one.
    @Test func shortcutsSkipHiddenRows() {
        let rooms = Array(dms.prefix(4)) + [Conversation.fixture("s1", name: "S", unread: 1)]
        #expect(Conversation.atShortcut(3, in: rooms, limit: 2)?.id == "s1")
        #expect(Conversation.atShortcut(3, in: rooms)?.id == "d3")
        #expect(Conversation.nextUnread(after: "d1", in: rooms, forward: true)?.id == "s1")
    }
}
