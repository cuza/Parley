import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

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
        let message = Message.fixture()
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
        let message = Message.fixture { $0.reactions = [Reaction(emoji: "👍", people: ["a"])] }
        let row = TimelineRow.rows([message])[0]
        view.configure(row, own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.frame = CGRect(
            x: 0, y: 0, width: 600, height: RowLayout.make(row, width: 600, own: false, kind: .space).height)
        view.layoutSubtreeIfNeeded()
        #expect(!view.subviews.contains { $0 is NSButton })  // made on the first hover: most rows are never hovered
        let event = try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: event)
        view.layoutSubtreeIfNeeded()
        let layout = try #require(view.rowLayout)
        #expect(!view.addReactionButton.isHidden)
        #expect(
            view.addReactionButton.frame.minX > layout.bubble.maxX
                && view.addReactionButton.frame.minY == layout.reactions[0].minY)
        #expect(view.addReactionButton.action == #selector(MessageRowView.showEmojiPicker))
    }
    @Test func theMenuTakesNoSystemItems() {
        let (view, _) = row(usage: usage())
        let menu = view.contextMenu()
        #expect(!menu.allowsContextMenuPlugIns)
        let titles = menu.items.map(\.title)
        menu.addItem(NSMenuItem(title: "Ask Siri", action: nil, keyEquivalent: ""))  // as the system appends at display
        menu.delegate?.menuWillOpen?(menu)
        #expect(menu.items.map(\.title) == titles)
    }
}
