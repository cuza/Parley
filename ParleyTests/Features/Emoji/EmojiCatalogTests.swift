import AppKit
import SwiftUI
import Testing

@testable import Parley

struct EmojiCatalogTests {
    @Test func everyCategoryHasEmojiAndNoEmojiRepeats() {
        let categories = EmojiCatalog.categories
        #expect(
            categories.map(\.name) == [
                "Smileys & People", "Animals & Nature", "Food & Drink", "Activity",
                "Travel & Places", "Objects", "Symbols", "Flags",
            ])
        for category in categories { #expect(category.emoji.count > 20, "\(category.name)") }
        let all = categories.flatMap(\.emoji).map(\.character)
        #expect(Set(all).count == all.count)
        #expect(all.count > 1000)
    }
    @Test func categoriesHoldWhatTheirNamesSay() {
        func category(of emoji: String) -> String? {
            EmojiCatalog.categories.first { $0.emoji.contains { $0.character == emoji } }?.name
        }
        #expect(category(of: "😀") == "Smileys & People")
        #expect(category(of: "🐶") == "Animals & Nature")
        #expect(category(of: "🍕") == "Food & Drink")
        #expect(category(of: "⚽") == "Activity")
        #expect(category(of: "🚗") == "Travel & Places")
        #expect(category(of: "💡") == "Objects")
        #expect(category(of: "❤️") == "Symbols")
        #expect(category(of: "🇫🇷") == "Flags")
        #expect(EmojiCatalog.categories[0].emoji.first?.character == "😀")
    }
    @Test func noSkinToneSwatchesOrLoneLettersOrDigits() {
        let all = Set(EmojiCatalog.categories.flatMap(\.emoji).map(\.character))
        for excluded in ["🏻", "🇦", "1", "#", "©"] { #expect(!all.contains(excluded)) }
    }
    @Test func searchMatchesNameWordsAndKeywords() {
        #expect(EmojiCatalog.search("thumbs up").first?.character == "👍")
        #expect(EmojiCatalog.search("heart").map(\.character).contains("❤️"))
        #expect(EmojiCatalog.search("Heart").map(\.character).contains("❤️"))
        #expect(EmojiCatalog.search("lol").first?.character == "😂")
        #expect(EmojiCatalog.search("france").map(\.character) == ["🇫🇷"])
        #expect(!EmojiCatalog.search("cat").map(\.character).contains("🎓"))  // word prefixes, not substrings ("eduCATion")
        #expect(EmojiCatalog.search("zzqx").isEmpty)
        #expect(EmojiCatalog.search("  ").isEmpty)
    }
    @Test func searchFindsEveryFacepalm() {
        let found = EmojiCatalog.search("facepalm").map(\.character)
        #expect(found.first == "🤦")  // the name run together is an exact match
        #expect(found.contains("🤦\u{200D}♂\u{FE0F}") && found.contains("🤦\u{200D}♀\u{FE0F}"))
        #expect(EmojiCatalog.search("man facepalm").first?.character == "🤦\u{200D}♂\u{FE0F}")
        #expect(EmojiCatalog.search("woman shrug").first?.character == "🤷\u{200D}♀\u{FE0F}")
    }
    @Test func searchFindsTheCommonShortcodes() {
        #expect(EmojiCatalog.search("thumbsup").first?.character == "👍")
        #expect(EmojiCatalog.search("+1").first?.character == "👍")
        #expect(EmojiCatalog.search("thumbsdown").first?.character == "👎")
        #expect(EmojiCatalog.search("joy").first?.character == "😂")
        #expect(EmojiCatalog.search("shrug").first?.character == "🤷")
        #expect(EmojiCatalog.search("tada").first?.character == "🎉")
        #expect(EmojiCatalog.search("eyes").first?.character == "👀")
        #expect(EmojiCatalog.search("heart eyes").first?.character == "😍")
        #expect(EmojiCatalog.search("fire").first?.character == "🔥")
    }
    @Test func searchRanksExactThenPrefixThenWordThenKeyword() {
        let found = EmojiCatalog.search("cat").map(\.character)
        #expect(found.first == "🐈")  // "cat" exactly
        let prefix = found.firstIndex(of: "🐱")!  // "cat face"
        let word = found.firstIndex(of: "😺")!  // "smiling cat face with open mouth"
        #expect(prefix < word)
        // Among equal matches, the ones I use come first.
        let hearts = EmojiCatalog.search("heart").map(\.character)
        #expect(hearts.firstIndex(of: "💙")! < hearts.firstIndex(of: "💜")!)
        let mine = EmojiCatalog.search("heart", frequent: ["💜"]).map(\.character)
        #expect(mine.firstIndex(of: "💜")! < mine.firstIndex(of: "💙")!)
    }
}
