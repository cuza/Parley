import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct MessageMenuTests {
    private func row(own: Bool) -> (MessageRowView, () -> [String]) {
        var calls: [String] = []
        let view = MessageRowView()
        let message = Message.fixture(from: own ? .fixture("me", name: "Me") : .fixture())
        view.configure(
            TimelineRow.rows([message])[0], own: own, kind: .space, meID: "me",
            actions: MessageRowActions(
                react: { emoji, _ in calls.append(emoji) }, openThread: { _ in calls.append("thread") },
                quote: { _ in calls.append("quote") }, retry: { _ in },
                copy: { _ in calls.append("copy") }, edit: { _ in calls.append("edit") },
                delete: { _ in calls.append("delete") }))
        return (view, { calls })
    }
    /// VoiceOver reads a message as one line, who and what and when, and offers the menu's actions on it.
    @Test func voiceOverReadsTheMessageAndOffersItsActions() throws {
        let (view, calls) = row(own: false)
        let label = try #require(view.accessibilityLabel())
        let message = try #require(view.row?.message)
        #expect(label.contains("\(message.sender.name), \(message.text)"))  // after the day, which this first row starts
        #expect(label.contains(message.createdAt.formatted(date: .omitted, time: .shortened)))
        let actions = try #require(view.accessibilityCustomActions())
        #expect(actions.map(\.name).starts(with: ["Reply", "Reply in Thread", "Copy"]))
        _ = actions.first { $0.name == "Reply" }?.handler?()
        #expect(calls() == ["quote"])
        let (own, _) = row(own: true)
        #expect(own.accessibilityLabel()?.contains(", You, hi, ") == true)
    }
    /// Copy Message keeps the message's links and formatting for Mail and Notes (rich text), and plain text for the rest.
    @Test func copyKeepsLinksAndFormatting() throws {
        let board = NSPasteboard(name: .init("parley-test-\(UUID().uuidString)"))
        MessageRowView.pasteboard = board
        defer { MessageRowView.pasteboard = .general }
        let view = MessageRowView()
        let message = Message.fixture("see docs") {
            $0.formatting = [TextStyleRange(style: .link(URL(string: "https://example.com")!), start: 4, length: 4)]
        }
        view.configure(
            TimelineRow.rows([message])[0], own: false, kind: .space, meID: "me", actions: MessageRowActions())
        let item = try #require(view.contextMenu().items.first { $0.title == "Copy" } as? ClosureMenuItem)
        item.handler()
        #expect(board.string(forType: .string) == "see docs")
        let rich = try #require(
            board.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        #expect(rich.attribute(.link, at: 5, effectiveRange: nil) != nil)
    }
    /// With text selected, the menu keeps the system's items for it (Look Up, Translate, Search, Services, Speech).
    @Test func selectedTextKeepsTheSystemItems() throws {
        let (view, _) = row(own: false)
        let menu = try #require(view.contextMenu(selection: "hi") as? MessageMenu)
        #expect(menu.keepsSystemItems)
        #expect(try #require(view.contextMenu() as? MessageMenu).keepsSystemItems == false)
    }
    @Test func theMenuStartsWithQuickReactionsThenActions() {
        let (incoming, _) = row(own: false)
        let menu = incoming.contextMenu()
        #expect(menu.items.first?.view is ReactionStrip)
        #expect(
            menu.items.dropFirst().filter { !$0.isSeparatorItem }.map(\.title) == ["Reply", "Reply in Thread", "Copy"])
        let (own, _) = row(own: true)
        #expect(
            own.contextMenu().items.dropFirst().filter { !$0.isSeparatorItem }.map(\.title) == [
                "Reply", "Reply in Thread", "Copy", "Edit", "Delete…",
            ])
    }
    /// Share… follows Copy Message Link and shares the same link. With text selected, the system's own Share (for the
    /// text) is the only one.
    @Test func shareOffersTheMessageLink() throws {
        let view = MessageRowView()
        let message = Message.fixture(id: "space/s1/t1/m1")
        view.configure(
            TimelineRow.rows([message])[0], own: false, kind: .space, meID: "me", actions: MessageRowActions())
        let titles = view.contextMenu().items.map(\.title)
        let link = try #require(titles.firstIndex(of: "Copy Message Link"))
        #expect(titles[link + 1] == "Share…")
        #expect(MessageRowView.shareItems(message) as? [URL] == [ChatLink.url(message: message.id)!])
        #expect(!view.contextMenu(selection: "hi").items.map(\.title).contains("Share…"))
    }
    @Test func markAsUnreadIsOfferedAndMarksFromThisMessage() throws {
        var marked: [MessageID] = []
        let view = MessageRowView()
        let message = Message.fixture()
        var actions = MessageRowActions()
        actions.markUnread = { marked.append($0.id) }
        view.configure(TimelineRow.rows([message])[0], own: false, kind: .space, meID: "me", actions: actions)
        let item = try #require(view.contextMenu().items.first { $0.title == "Mark as Unread" })
        item.target.map { _ = ($0 as AnyObject).perform(item.action, with: item) }
        #expect(marked == ["m"])
    }
    @Test func replyQuotesAndReplyInThreadOpensTheThread() throws {
        let (view, calls) = row(own: false)
        for title in ["Reply", "Reply in Thread"] {
            let item = try #require(view.contextMenu().items.first { $0.title == title })
            item.target.map { _ = ($0 as AnyObject).perform(item.action, with: item) }
        }
        #expect(calls() == ["quote", "thread"])
    }
    /// A deleted message offers nothing, as on the web: no menu to quote, react to or forward it.
    @Test func aDeletedMessageHasNoMenu() throws {
        let view = MessageRowView()
        let gone = Message.fixture("Message deleted") { $0.tombstone = true }
        view.configure(TimelineRow.rows([gone])[0], own: false, kind: .space, meID: "me", actions: MessageRowActions())
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(view.menu(for: event) == nil && view.emojiPopover() == nil)
        let textMenu = view.textView.menu(for: event)?.items.map(\.title) ?? []  // the system's text menu at most
        #expect(!textMenu.contains("Reply") && !textMenu.contains("Forward…"))
    }
    @Test func theTextMenuIsTheSameMenu() throws {
        let (view, _) = row(own: true)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(
            try #require(view.textView.menu(for: event)).items.map(\.title) == view.contextMenu().items.map(\.title))
    }
    @Test func unsentMessagesCannotBeQuoted() {
        let view = MessageRowView()
        let message = Message.fixture(from: .fixture("me", name: "Me"), delivery: .failed)
        view.configure(
            TimelineRow.rows([message])[0], own: true, kind: .space, meID: "me", actions: MessageRowActions())
        #expect(!view.contextMenu().items.map(\.title).contains("Reply"))
    }
    @Test func aQuickReactionReacts() throws {
        let (view, calls) = row(own: false)
        let strip = try #require(view.contextMenu().items.first?.view as? ReactionStrip)
        strip.buttons[1].performClick(nil)
        #expect(calls() == [EmojiUsage.defaults[1]])
    }
}
