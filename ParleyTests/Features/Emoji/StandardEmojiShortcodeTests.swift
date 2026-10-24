import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct StandardEmojiShortcodeTests {
    @Test func aColonQueryOffersStandardEmojiAfterCustomOnesAndInsertsThem() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.customEmoji = [CustomEmoji(id: "t", shortcode: "thumbs-party")]
        view.load("", [])
        view.insertText(":thumbs", replacementRange: view.selectedRange())
        let matches = view.mentionMatches
        #expect(matches.first == .emoji(CustomEmoji(id: "t", shortcode: "thumbs-party")))
        let thumbs = try #require(
            matches.first { if case .unicode(let emoji) = $0 { emoji.character == "👍" } else { false } })
        view.insert(thumbs, replacing: view.mentionQuery!.range)
        #expect(view.draftText == "👍 " && view.mentionQuery == nil)
    }
    @Test func oneLetterAfterAColonOffersNoStandardEmoji() {  // ":D" and "a:b" stay text, and Return still sends
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("", [])
        view.insertText(":D", replacementRange: view.selectedRange())
        #expect(view.mentionMatches.isEmpty)
    }
    @Test func aColonShortcodeFindsFacepalm() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("", [])
        view.insertText(":facepalm", replacementRange: view.selectedRange())
        #expect(view.mentionMatches.first == .unicode(EmojiCatalog.emoji("🤦")))
        #expect(view.mentionMatches.contains(.unicode(EmojiCatalog.emoji("🤦\u{200D}♂\u{FE0F}"))))
    }
}
