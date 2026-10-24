import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// The @ list in sections, as Google Chat shows it: People, then Files, then Spaces, each under its name.
@MainActor struct MentionSectionTests {
    @Test func sectionsAreNamedAndOrderedAsGoogleChatShowsThem() {
        let person = Suggestion.person(Person(id: "p", name: "Pat"))
        let file = Suggestion.file(DriveChipTests.plan)
        let room = Suggestion.room(Conversation.fixture("space/s", name: "Plans"))
        #expect(MentionList.headers([person, file, room]) == [0: "People", 1: "Files", 2: "Spaces"])
        #expect(MentionList.headers([person, .person(Person(id: "q", name: "Quinn"))]) == [0: "People"])
        #expect(MentionList.headers([.emoji(CustomEmoji(id: "e", shortcode: "e"))]).isEmpty)  // a :shortcode list has none
        // The popup grows by a header's height for each, up to 8 rows' worth, then scrolls.
        #expect(
            MentionPopup.height(rows: 3, headers: 3) == 3 * MentionList.rowHeight + 3 * MentionList.headerHeight + 8)
        #expect(MentionPopup.height(rows: 20, headers: 3) == 8 * MentionList.rowHeight + 8)
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.mentionPeople = [Person(id: "p", name: "Plato")]
        view.chipConversations = [Conversation.fixture("space/s", name: "Plans")]
        view.load("", [])
        view.insertText("@pl", replacementRange: view.selectedRange())
        view.driveFiles = Found(query: "pl", items: [DriveChipTests.plan])
        #expect(view.mentionMatches.map(\.id) == ["p:p", "f:f1", "r:space/s"])
    }
    /// People beyond the members come from the directory, after the members who match, as Google Chat lists them; a
    /// member the directory also finds shows once.
    @Test func directoryPeopleFollowTheMembers() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        let plato = Person(id: "p", name: "Plato")
        let wu = Person(id: "w", name: "Wu Pell")
        view.mentionPeople = [plato]
        view.load("", [])
        view.insertText("@p", replacementRange: view.selectedRange())
        view.directoryPeople = Found(query: "p", items: [wu, plato])
        #expect(view.mentionMatches.map(\.id) == ["p:p", "p:w"])
        #expect(MentionList.headers(view.mentionMatches) == [0: "People"])
    }
    @Test func theStoreAsksTheDirectoryButNotForItself() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.searchMentionResults("design", "sa")
        await eventually { !store.lookups.directoryPeople.items.isEmpty }
        #expect(store.lookups.directoryPeople == Found(query: "sa", items: [FakeBackend.directoryPerson]))
    }
}
