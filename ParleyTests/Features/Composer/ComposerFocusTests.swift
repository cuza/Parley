import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// The Format menu acts on the composer being typed in, and is off when none is.
@MainActor struct ComposerFocusTests {
    @Test func theFocusedComposerIsTracked() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let composer = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let other = NSTextField(frame: NSRect(x: 0, y: 50, width: 300, height: 24))
        window.contentView?.addSubview(composer)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(composer)
        #expect(ComposerFocus.shared.composer === composer)
        window.makeFirstResponder(other)
        #expect(ComposerFocus.shared.composer == nil)
    }
}

/// Opening a conversation puts the keyboard in its composer, as opening a thread does.
@MainActor struct ConversationComposerFocusTests {
    @Observable final class Shown {
        var conversation: Conversation
        init(_ conversation: Conversation) { self.conversation = conversation }
    }
    struct Harness: View {
        let store: ChatStore
        let shown: Shown
        var body: some View {
            ComposerBar(conversation: shown.conversation).environment(store).frame(width: 500, height: 120)
        }
    }
    /// Suspends the test, so the main queue runs what the composer put off until its window settles.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    @Test func aConversationsComposerTakesTheKeyboardWhenItOpens() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let alex = try #require(store.rooms.conversations.first { $0.id == "alex" })
        let maria = try #require(store.rooms.conversations.first { $0.id == "maria" })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = NSTableView(frame: NSRect(x: 0, y: 150, width: 100, height: 50))
        let shown = Shown(alex)
        let host = NSHostingView(rootView: Harness(store: store, shown: shown))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 150)
        window.contentView?.addSubview(host)
        window.contentView?.addSubview(sidebar)
        try await settle()
        #expect(window.firstResponder is ComposerTextView)
        window.makeFirstResponder(sidebar)  // a click on another conversation in the sidebar
        shown.conversation = maria
        try await settle()
        #expect(window.firstResponder is ComposerTextView)
    }

    /// ↑ and ↓ in the sidebar move its selection; the sidebar keeps the keyboard for the next one.
    @Test func arrowKeysInAListKeepTheKeyboardThere() throws {
        func key(_ code: UInt16, _ type: NSEvent.EventType = .keyDown) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
        }
        let list = NSTableView()
        #expect(ComposerTextView.browsingList(list, key(125)))  // ↓
        #expect(ComposerTextView.browsingList(list, key(126, .keyUp)))  // ↑, let go
        #expect(!ComposerTextView.browsingList(list, key(36)))  // Return opens it from a list: the composer takes it
        #expect(!ComposerTextView.browsingList(NSTextView(), key(125)))  // ⌥⌘↓ from the composer
        let click = NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0)
        #expect(!ComposerTextView.browsingList(list, click))
        #expect(!ComposerTextView.browsingList(list, nil))
    }

    /// The sidebar is a SwiftUI List, which AppKit draws with a table view: what `browsingList` looks for.
    @Test func aSwiftUIListIsATableView() {
        let host = NSHostingView(
            rootView: List(selection: .constant("a")) { Text("a").tag("a") }.listStyle(.sidebar).frame(
                width: 200, height: 100))
        host.layoutSubtreeIfNeeded()
        func tables(_ view: NSView) -> Bool { view is NSTableView || view.subviews.contains(where: tables) }
        #expect(tables(host))
    }
}
