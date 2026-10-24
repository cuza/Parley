import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct TextMenuTests {
    @Test func rightClickingTheTextOpensTheMessageMenu() throws {
        var copied: [String] = []
        let view = MessageRowView()
        view.configure(
            TimelineRow.rows([.fixture("hello there")])[0],
            own: false, kind: .space, meID: "me", actions: MessageRowActions(copy: { copied.append($0.text) }))
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.textView.menu(for: event))
        #expect(menu.items.first?.view is ReactionStrip)
        view.textView.setSelectedRange(NSRange(location: 0, length: 5))  // with a selection, Copy copies just that
        let copy = try #require(view.textView.menu(for: event)?.items.first { $0.title == "Copy" })
        NSPasteboard.general.clearContents()
        copy.target.map { _ = ($0 as AnyObject).perform(copy.action, with: copy) }
        #expect(NSPasteboard.general.string(forType: .string) == "hello" && copied.isEmpty)
    }
}
