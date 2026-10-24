import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// The picker's sections: built once per search and list, not at each hover.
@MainActor struct EmojiPickerSectionTests {
    static let parrot = CustomEmoji(
        id: "p", shortcode: "party-parrot", imageURL: URL(string: "https://example.invalid/p"))
    /// A workspace with thousands of its own emoji keeps the standard ones near: the workspace's come last.
    @Test func customEmojiComeAfterTheStandardOnes() {
        let titles = EmojiPicker.sections(query: "", custom: [Self.parrot], frequent: ["👍"]).map(\.title)
        #expect(titles.first == "Frequently Used")
        #expect(titles.last == "Custom")
        #expect(titles.dropFirst().dropLast() == ArraySlice(EmojiCatalog.categories.map(\.name)))
    }
    /// The arrow keys scroll to the row holding the selection: rows of 9, counted within their section.
    @Test func theSelectionsRowIsCountedWithinItsSection() {
        let starts = [0, 5, 30]  // sections of 5, 25 and more
        #expect(EmojiPicker.rowID(of: 3, starts: starts, columns: 9) == "row 0 0")
        #expect(EmojiPicker.rowID(of: 5, starts: starts, columns: 9) == "row 1 0")
        #expect(EmojiPicker.rowID(of: 23, starts: starts, columns: 9) == "row 1 2")
        #expect(EmojiPicker.rowID(of: 40, starts: starts, columns: 9) == "row 2 1")
    }
    /// Each cell knows its own custom emoji, so drawing one looks nothing up.
    @Test func customCellsCarryTheirEmoji() {
        let custom = EmojiPicker.sections(query: "", custom: [Self.parrot], frequent: []).last?.emoji
        #expect(custom?.map(\.custom) == [Self.parrot])
        let found = EmojiPicker.sections(query: "parrot", custom: [Self.parrot], frequent: []).first?.emoji.first
        #expect(found?.custom == Self.parrot && found?.character == ":party-parrot:")
        #expect(EmojiCatalog.categories.first?.emoji.first?.custom == nil)
    }
}
