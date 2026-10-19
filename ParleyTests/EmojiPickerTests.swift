import AppKit
import SwiftUI
import Testing
@testable import Parley

struct EmojiCatalogTests {
    @Test func everyCategoryHasEmojiAndNoEmojiRepeats() {
        let categories = EmojiCatalog.categories
        #expect(categories.map(\.name) == ["Smileys & People", "Animals & Nature", "Food & Drink", "Activity",
                                           "Travel & Places", "Objects", "Symbols", "Flags"])
        for category in categories { #expect(category.emoji.count > 20, "\(category.name)") }
        let all = categories.flatMap(\.emoji).map(\.character)
        #expect(Set(all).count == all.count)
        #expect(all.count > 1000)
    }
    @Test func categoriesHoldWhatTheirNamesSay() {
        func category(of emoji: String) -> String? { EmojiCatalog.categories.first { $0.emoji.contains { $0.character == emoji } }?.name }
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
        #expect(!EmojiCatalog.search("cat").map(\.character).contains("🎓"))   // word prefixes, not substrings ("eduCATion")
        #expect(EmojiCatalog.search("zzqx").isEmpty)
        #expect(EmojiCatalog.search("  ").isEmpty)
    }
    @Test func searchFindsEveryFacepalm() {
        let found = EmojiCatalog.search("facepalm").map(\.character)
        #expect(found.first == "🤦")   // the name run together is an exact match
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
        #expect(found.first == "🐈")   // "cat" exactly
        let prefix = found.firstIndex(of: "🐱")!   // "cat face"
        let word = found.firstIndex(of: "😺")!   // "smiling cat face with open mouth"
        #expect(prefix < word)
        // Among equal matches, the ones I use come first.
        let hearts = EmojiCatalog.search("heart").map(\.character)
        #expect(hearts.firstIndex(of: "💙")! < hearts.firstIndex(of: "💜")!)
        let mine = EmojiCatalog.search("heart", frequent: ["💜"]).map(\.character)
        #expect(mine.firstIndex(of: "💜")! < mine.firstIndex(of: "💙")!)
    }
}

struct EmojiUsageTests {
    private func usage() -> EmojiUsage {
        let name = "EmojiUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return EmojiUsage(defaults: defaults)
    }
    @Test func withoutHistoryTheQuickReactionsAreTheDefaults() {
        #expect(usage().top(6) == EmojiUsage.defaults)
        #expect(usage().top(3) == Array(EmojiUsage.defaults.prefix(3)))
    }
    @Test func theMostUsedComeFirstThenTheDefaults() {
        let usage = usage()
        usage.record("🦊"); usage.record("🦊"); usage.record("🎉"); usage.record("😂")
        #expect(usage.top(6) == ["🦊", "😂", "🎉", "👍", "❤️", "😮"])   // on a tie a default comes first
        #expect(usage.top(9) == ["🦊", "😂", "🎉", "👍", "❤️", "😮", "😢", "🙏"])   // only the defaults pad it
    }
    @Test func countsPersistInTheDefaults() {
        let first = usage()
        first.record("🦊")
        #expect(EmojiUsage(defaults: first.defaults).top(1) == ["🦊"])
    }
}

struct EmojiGridTests {
    // Two sections: 5 emoji (rows of 3: 3 + 2), then 4 (3 + 1). Flat indices 0…4, 5…8.
    let sizes = [5, 4]
    @Test func leftAndRightStepThroughTheFlatList() {
        #expect(EmojiGrid.move(0, .left, sizes: sizes, columns: 3) == 0)
        #expect(EmojiGrid.move(4, .right, sizes: sizes, columns: 3) == 5)
        #expect(EmojiGrid.move(8, .right, sizes: sizes, columns: 3) == 8)
    }
    @Test func upAndDownKeepTheColumnAcrossSections() {
        #expect(EmojiGrid.move(1, .down, sizes: sizes, columns: 3) == 4)
        #expect(EmojiGrid.move(2, .down, sizes: sizes, columns: 3) == 4)   // the short last row: its last emoji
        #expect(EmojiGrid.move(4, .down, sizes: sizes, columns: 3) == 6)   // into the next section, same column
        #expect(EmojiGrid.move(6, .up, sizes: sizes, columns: 3) == 4)
        #expect(EmojiGrid.move(5, .up, sizes: sizes, columns: 3) == 3)
        #expect(EmojiGrid.move(8, .down, sizes: sizes, columns: 3) == 8)
        #expect(EmojiGrid.move(1, .up, sizes: sizes, columns: 3) == 1)
    }
}

@MainActor struct EmojiReactionMenuTests {
    private func usage() -> EmojiUsage {
        let name = "EmojiReactionMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return EmojiUsage(defaults: defaults)
    }
    private func row(usage: EmojiUsage) -> (MessageRowView, () -> [String]) {
        var calls: [String] = []
        let view = MessageRowView()
        let message = Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "X"), text: "hi")
        var actions = MessageRowActions(react: { emoji, _ in calls.append(emoji) })
        actions.emojiUsage = usage
        view.configure(TimelineRow.rows([message])[0], own: false, kind: .space, meID: "me", actions: actions)
        return (view, { calls })
    }
    @Test func theStripShowsTheMostUsedReactionsAndAMoreButton() throws {
        let usage = usage()
        usage.record("🦊")
        let (view, _) = row(usage: usage)
        let strip = try #require(view.contextMenu().items.first?.view as? ReactionStrip)
        #expect(strip.emoji == ["🦊", "👍", "❤️", "😂", "😮", "😢"])
        #expect(strip.buttons.map(\.title) == strip.emoji)
        #expect(strip.moreButton.accessibilityLabel() == "More reactions")
    }
    @Test func aQuickReactionReactsAndCounts() throws {
        let usage = usage()
        let (view, calls) = row(usage: usage)
        let strip = try #require(view.contextMenu().items.first?.view as? ReactionStrip)
        strip.buttons[2].performClick(nil)
        #expect(calls() == ["😂"])
        #expect(usage.top(1) == ["😂"])
    }
    @Test func thePickerReactsCountsAndCloses() throws {
        let usage = usage()
        let (view, calls) = row(usage: usage)
        let popover = try #require(view.emojiPopover())
        let picker = try #require((popover.contentViewController as? NSHostingController<EmojiPicker>)?.rootView)
        picker.pick("🦊")
        #expect(calls() == ["🦊"])
        #expect(usage.top(1) == ["🦊"])
    }
    @Test func hoveringAMessageWithReactionsOffersToAddOne() throws {
        let view = MessageRowView()
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "X"), text: "hi")
        message.reactions = [Reaction(emoji: "👍", people: ["a"])]
        let row = TimelineRow.rows([message])[0]
        view.configure(row, own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.frame = CGRect(x: 0, y: 0, width: 600, height: RowLayout.make(row, width: 600, own: false, kind: .space).height)
        view.layoutSubtreeIfNeeded()
        #expect(!view.subviews.contains { $0 is NSButton })   // made on the first hover: most rows are never hovered
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: event)
        view.layoutSubtreeIfNeeded()
        let layout = try #require(view.rowLayout)
        #expect(!view.addReactionButton.isHidden)
        #expect(view.addReactionButton.frame.minX > layout.bubble.maxX && view.addReactionButton.frame.minY == layout.reactions[0].minY)
        #expect(view.addReactionButton.action == #selector(MessageRowView.showEmojiPicker))
    }
    @Test func theMenuTakesNoSystemItems() {
        let (view, _) = row(usage: usage())
        let menu = view.contextMenu()
        #expect(!menu.allowsContextMenuPlugIns)
        let titles = menu.items.map(\.title)
        menu.addItem(NSMenuItem(title: "Ask Siri", action: nil, keyEquivalent: ""))   // as the system appends at display
        menu.delegate?.menuWillOpen?(menu)
        #expect(menu.items.map(\.title) == titles)
    }
}

@MainActor struct ComposerEmojiTests {
    private final class Changes: NSObject, NSTextViewDelegate {
        var drafts: [String] = []
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? ComposerTextView { drafts.append(view.string) }
        }
    }
    private func composer() -> (ComposerHandle, ComposerTextView, NSWindow, Changes) {
        let changes = Changes()
        let scroll = NativeComposer.makeScrollView(delegate: changes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 42), styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        let view = scroll.documentView as! ComposerTextView
        let name = "ComposerEmojiTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let handle = ComposerHandle(usage: EmojiUsage(defaults: defaults))
        handle.view = view
        return (handle, view, window, changes)
    }
    @Test func aPickedEmojiGoesInAtTheCaretAndLaterFormattingMovesWithTheText() {
        let (handle, view, window, changes) = composer()
        view.load("hi there", [TextStyleRange(style: .bold, start: 3, length: 5)])
        view.setSelectedRange(NSRange(location: 2, length: 0))
        window.makeFirstResponder(nil)   // the picker had the focus
        var closed = false
        handle.emojiPicker(close: { closed = true }).pick("🦊")
        #expect(view.string == "hi🦊 there")
        #expect(view.formatting == [TextStyleRange(style: .bold, start: 5, length: 5)])   // 🦊 is two UTF-16 units
        #expect(view.selectedRange() == NSRange(location: 4, length: 0))
        #expect(changes.drafts.last == "hi🦊 there")   // the store hears of it
        #expect(handle.usage.top(1) == ["🦊"])
        #expect(closed)
        #expect(window.firstResponder === view)
    }
    @Test func aPickedEmojiReplacesTheSelection() {
        let (handle, view, _, _) = composer()
        view.load("hi there you", [TextStyleRange(style: .italic, start: 9, length: 3)])
        view.setSelectedRange(NSRange(location: 3, length: 5))   // "there"
        handle.emojiPicker(close: {}).pick("👋")
        #expect(view.string == "hi 👋 you")
        #expect(view.formatting == [TextStyleRange(style: .italic, start: 6, length: 3)])
    }
    @Test func thePickerOffersTheMostUsedFirst() {
        let (handle, _, _, _) = composer()
        handle.usage.record("🦊")
        #expect(handle.emojiPicker(close: {}).frequent.first == "🦊")
    }
}

/// The picker's sections: built once per search and list, not at each hover.
@MainActor struct EmojiPickerSectionTests {
    static let parrot = CustomEmoji(id: "p", shortcode: "party-parrot", imageURL: URL(string: "https://example.invalid/p"))
    /// A workspace with thousands of its own emoji keeps the standard ones near: the workspace's come last.
    @Test func customEmojiComeAfterTheStandardOnes() {
        let titles = EmojiPicker.sections(query: "", custom: [Self.parrot], frequent: ["👍"]).map(\.title)
        #expect(titles.first == "Frequently Used")
        #expect(titles.last == "Custom")
        #expect(titles.dropFirst().dropLast() == ArraySlice(EmojiCatalog.categories.map(\.name)))
    }
    /// The arrow keys scroll to the row holding the selection: rows of 9, counted within their section.
    @Test func theSelectionsRowIsCountedWithinItsSection() {
        let starts = [0, 5, 30]   // sections of 5, 25 and more
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
