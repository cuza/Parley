import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

struct CustomEmojiAnnotationTests {
    private let parrot = DynamiteMapper.customEmoji(listedEmoji("a", "parrot"))!
    @Test func customEmojiBecomesAnAnnotationWithItsPayloadBesideMentionsAndBold() throws {
        // "hi 👍\u{FFFD} @Ana": 👍 is two UTF-16 units, so the emoji is at 5.
        let formatting = [
            TextStyleRange(style: .bold, start: 0, length: 2),
            TextStyleRange(style: .customEmoji(parrot), start: 5, length: 1),
            TextStyleRange(style: .mention(userID: "u2"), start: 7, length: 4),
        ]
        let annotations = DynamiteMapper.annotations(formatting)
        #expect(annotations.map(\.type) == [.formatData, .customEmoji, .userMention])
        let emoji = annotations[1]
        #expect(emoji.startIndex == 5 && emoji.length == 1)
        #expect(emoji.customEmojiMetadata.customEmoji == listedEmoji("a", "parrot"))
    }
    @Test func anEditedMessageKeepsItsCustomEmoji() {
        let (text, formatting) = DynamiteMapper.richText(
            "a\u{FFFD}",
            [
                .with {
                    $0.type = .customEmoji
                    $0.startIndex = 1
                    $0.length = 1
                    $0.customEmojiMetadata.customEmoji = listedEmoji("a", "parrot")
                }
            ])
        #expect(text == "a\u{FFFD}")
        #expect(
            DynamiteMapper.annotations(formatting).first?.customEmojiMetadata.customEmoji == listedEmoji("a", "parrot"))
    }
    @Test func aShortcodeStoredWithColonsShowsThemOnce() {
        #expect(DynamiteMapper.customEmoji(listedEmoji("m", ":masabito:"))?.text == ":masabito:")
        #expect(DynamiteMapper.customEmoji(listedEmoji("m", "masabito"))?.text == ":masabito:")
    }
}
