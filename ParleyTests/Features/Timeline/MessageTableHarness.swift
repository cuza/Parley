import AppKit
import SwiftUI

@testable import Parley
@testable import ParleyDomain

/// The timeline table in a window, for the table's tests: shows messages as the conversation view would, and records
/// what the table reports back.
@MainActor final class MessageTableHarness {
    static let alex = Person(id: "alex", name: "Alex"), me = Person(id: "me", name: "Me")
    private static let lines = [
        "ok", "What can you do?", String(repeating: "A long message that wraps when the window is narrow. ", count: 5),
        "Unsupported message",
    ]
    /// Messages `range`, a minute apart; every third is mine.
    static func messages(_ range: Range<Int>) -> [Message] {
        range.map { index in
            Message.fixture(
                lines[index % lines.count], id: MessageID(String(format: "m%04d", index)),
                from: index % 3 == 0 ? me : alex,
                at: Message.fixtureDate + Double(index) * 60)
        }
    }

    let coordinator = MessageTable.Coordinator()
    let scroll: NSScrollView
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered,
        defer: false)
    var atBottom: [Bool] = []
    var nearTop = 0  // requests for older history
    var nearBottom = 0  // a detached window's requests for newer history
    var actions = MessageRowActions()
    var table: NSTableView {
        guard let table = scroll.documentView as? NSTableView else {
            preconditionFailure("MessageTable's document view is its table")
        }
        return table
    }
    init() {
        scroll = MessageTable.makeScrollView(coordinator, identifier: "t")
        scroll.scrollerStyle = .overlay  // as with a trackpad: a mouse's always-visible scroll bar would narrow the rows
        window.contentView = scroll
    }
    func show(
        _ messages: [Message], seen: [MessageID: [String]] = [:], scrollRequest: Int = 0, bottomInset: CGFloat = 0,
        highlighted: MessageID? = nil, detached: Bool = false
    ) {
        coordinator.update(
            MessageTable(
                rows: TimelineRow.rows(messages, seen: seen), meID: "me", kind: .space, highlighted: highlighted,
                actions: actions,
                nearTop: { [weak self] in self?.nearTop += 1 }, nearBottom: { [weak self] in self?.nearBottom += 1 },
                detached: detached, atBottomChanged: { [weak self] in self?.atBottom.append($0) },
                scrollRequest: scrollRequest,
                bottomInset: bottomInset))
        settle()
    }
    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    func scroll(to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
    }
    var visibleTop: CGFloat { scroll.documentVisibleRect.minY }
    var clip: NSRect { scroll.contentView.bounds }
    /// How far above the composer the newest message ends (0 when it rests just above it).
    var gapAboveComposer: CGFloat { clip.maxY - scroll.contentInsets.bottom - table.bounds.height }
}

/// `MessageTable` with a coordinator the test holds, so it can look at the table SwiftUI lays out.
struct MessageTableHost: NSViewRepresentable {
    let coordinator: MessageTable.Coordinator
    let table: MessageTable
    func makeNSView(context: Context) -> NSScrollView { MessageTable.makeScrollView(coordinator, identifier: "t") }
    func updateNSView(_ scroll: NSScrollView, context: Context) { coordinator.update(table) }
}
