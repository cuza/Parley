import AppKit
import SwiftUI
import Testing

@testable import Parley

/// The whole window as the app shows it: opening a thread beside a conversation narrows the timeline, and its rows
/// must follow (the README's thread screenshot showed bubbles clipped to their old height).
@MainActor struct TimelineInWindowTests {
    @Test func openingAThreadRemeasuresTheConversationsRows() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let host = NSHostingView(rootView: ChatView().environment(store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = host
        func settle() async {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await settle()
        let threaded = try #require(
            store.history.messages.first { $0.conversationID == store.navigation.selectedID && $0.replyCount > 0 })
        await store.openThread(threaded)
        await settle()
        func tables(_ view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        let timeline = try #require(
            tables(host).filter { $0.numberOfRows > 0 }.max { $0.bounds.width < $1.bounds.width })
        for index in 0..<timeline.numberOfRows {
            guard let view = timeline.rowView(atRow: index, makeIfNecessary: false) as? MessageRowView,
                let layout = view.rowLayout
            else { continue }
            #expect(
                timeline.rect(ofRow: index).height == layout.height,
                "row \(index): row \(timeline.rect(ofRow: index).height), layout \(layout.height) at \(timeline.bounds.width)"
            )
        }
    }
}
