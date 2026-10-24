import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// A conversation with no messages yet: the composer still spans the timeline (it shrank to the placeholder's width).
@MainActor struct EmptyConversationTests {
    @Test func theComposerSpansAnEmptyConversation() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let empty = Conversation.fixture("dm/nobody-yet", kind: .direct, name: "New")
        let host = NSHostingView(
            rootView: TimelineView(conversation: empty).environment(store).frame(width: 800, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] {
            ((view as? NSTextView).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(editors)
        }
        let composer = try #require(editors(host).first)
        #expect(
            composer.convert(composer.bounds, to: host).width > 500,
            "composer is \(composer.bounds.width) wide in an 800 pt timeline")
    }
}
