import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

@MainActor struct CustomEmojiComposerTests {
    private let parrot = CustomEmoji(
        id: "a", shortcode: "parrot", imageURL: URL(string: "https://example.invalid/parrot"), payload: Data([1, 2]))
    private let party = CustomEmoji(
        id: "b", shortcode: "party-parrot", imageURL: URL(string: "https://example.invalid/party"))

    @Test func anInsertedEmojiIsAnAttachmentAndAU_FFFDInTheDraft() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("👍 ", [])
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertCustomEmoji(parrot, replacing: view.selectedRange())
        view.insertCustomEmoji(parrot, replacing: view.selectedRange())  // equal neighbours stay two emoji
        view.insertText("x", replacementRange: view.selectedRange())  // typed after it: plain text
        #expect(view.textStorage?.attribute(.attachment, at: 3, effectiveRange: nil) is NSTextAttachment)
        #expect(view.draftText == "👍 \u{FFFD}\u{FFFD}x")
        let expected = [
            TextStyleRange(style: .customEmoji(parrot), start: 3, length: 1),
            TextStyleRange(style: .customEmoji(parrot), start: 4, length: 1),
        ]
        #expect(view.formatting == expected)
        // A saved draft loads back as the same emoji.
        let reloaded = ComposerTextView(usingTextLayoutManager: false)
        reloaded.load(view.draftText, view.formatting + [TextStyleRange(style: .bold, start: 5, length: 1)])
        #expect(reloaded.draftText == view.draftText)
        #expect(Set(reloaded.formatting) == Set(expected + [TextStyleRange(style: .bold, start: 5, length: 1)]))
        #expect(reloaded.textStorage?.attribute(.attachment, at: 4, effectiveRange: nil) is NSTextAttachment)
    }
    @Test func aColonQueryOffersShortcodes() {
        #expect(
            MentionQuery.find(in: "hi :sh", caret: 6, shortcode: true)
                == MentionQuery(range: NSRange(location: 3, length: 3), text: "sh", shortcode: true))
        #expect(MentionQuery.find(in: "at 10:30", caret: 8, shortcode: true) == nil)
        #expect(MentionQuery.find(in: "hi :", caret: 4, shortcode: true) == nil)
        #expect(MentionQuery.find(in: ":a b", caret: 4, shortcode: true) == nil)
        #expect(MentionQuery.nearest(in: "@ana :par", caret: 9)?.shortcode == true)
        #expect(MentionQuery.nearest(in: "@ana", caret: 4)?.shortcode == false)
        #expect(MentionQuery.filter([party, parrot], by: "PAR").map(\.id) == ["a", "b"])
        #expect(MentionQuery.filter([party, parrot], by: "ty").map(\.id) == ["b"])
    }
    /// Each new ":" query asks for a server search with what follows the colon.
    @Test func typingAShortcodeSearchesAsItGoes() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var searched: [String] = []
        view.searchCustomEmoji = { searched.append($0) }
        view.insertText(":s", replacementRange: view.selectedRange())
        view.insertText("a", replacementRange: view.selectedRange())
        #expect(searched == ["s", "sa"])
    }
    /// A workspace with thousands of emoji matches far more than a list can show: every match is offered (to 100), and
    /// the list scrolls past 8 rows.
    @Test func aShortcodeOffersEveryMatchInAScrollingList() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.customEmoji = (0..<150).map {
            CustomEmoji(id: "c\($0)", shortcode: "cat-\($0)", imageURL: URL(string: "https://example.invalid/c\($0)"))
        }
        view.insertText(":cat", replacementRange: view.selectedRange())
        #expect(view.mentionMatches.filter { if case .emoji = $0 { true } else { false } }.count == 100)
        #expect(MentionPopup.height(rows: 3) == 3 * MentionList.rowHeight + 8)
        #expect(MentionPopup.height(rows: 100) == 8 * MentionList.rowHeight + 8)
    }
    @Test func typingAShortcodeAsksForTheListAndPickingInsertsTheEmoji() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var asked = 0
        view.needCustomEmoji = { asked += 1 }
        view.customEmoji = [parrot, party]
        view.load("", [])
        view.insertText(":parr", replacementRange: view.selectedRange())
        #expect(asked == 1 && view.mentionQuery?.shortcode == true)
        view.insertCustomEmoji(parrot, replacing: view.mentionQuery!.range, space: true)
        #expect(
            view.draftText == "\u{FFFD} "
                && view.formatting == [TextStyleRange(style: .customEmoji(parrot), start: 0, length: 1)])
    }
    @Test func aDraftWithCustomEmojiSurvivesTheLaunchCache() async throws {
        let cache = LaunchCache(url: URL.temporaryDirectory.appending(path: "parley-cache-\(UUID().uuidString).json"))
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        let formatting = [TextStyleRange(style: .customEmoji(parrot), start: 3, length: 1)]
        store.setDraft("hi \u{FFFD}", formatting: formatting, conversation: "design", thread: nil)
        store.flush()
        let reopened = ChatStore(backend: FakeBackend(), cache: cache)
        #expect(reopened.drafting.text.values.contains("hi \u{FFFD}"))
        #expect(reopened.drafting.formatting.values.contains(formatting))
    }
    @Test func theOrganisationsEmojiLoadOncePerSession() async {
        let store = ChatStore(backend: FakeBackend())
        await store.loadCustomEmoji()
        await store.loadCustomEmoji()
        #expect(store.lookups.customEmoji.map(\.shortcode) == ["ship-it", "lgtm", "party-parrot"])
    }
}
