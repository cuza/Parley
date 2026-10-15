import AppKit
import SwiftUI
import Testing
@testable import Parley

/// The thread pane's header shows the thread's first message, at any width: beside the conversation, or filling a window.
@MainActor struct ThreadHeaderTests {
    private func header(width: CGFloat) async throws -> NativeMessageText.TextView {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("general")   // its timeline holds the thread's first message
        let room = try #require(store.conversations.first { $0.id == "general" })
        let host = NSHostingView(rootView: ThreadPane(store: store, room: room, thread: "g1", detached: true).frame(width: width, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
        func find(_ view: NSView) -> NativeMessageText.TextView? { (view as? NativeMessageText.TextView) ?? view.subviews.lazy.compactMap(find).first }
        return try #require(find(host))
    }
    @Test(arguments: [340, 900] as [CGFloat])
    func theFirstMessageShows(width: CGFloat) async throws {
        let text = try await header(width: width)
        let shown = try #require(text.layoutManager).usedRect(for: try #require(text.textContainer))
        #expect(text.string.contains("release notes"))
        #expect(text.frame.width > 0 && text.frame.height > 0, "frame \(text.frame)")
        #expect(shown.width > 0 && shown.width <= text.frame.width + 1, "laid out \(shown) in \(text.frame)")
    }
}
