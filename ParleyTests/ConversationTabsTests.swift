import AppKit
import Testing
@testable import Parley

/// Conversation windows open as tabs of the conversation window already open; other windows stay apart.
@MainActor struct ConversationTabsTests {
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }
    @Test func aSecondConversationWindowJoinsTheFirstAsATab() {
        let main = Self.window(), first = Self.window(), second = Self.window()
        defer { [main, first, second].forEach { $0.close() } }
        ConversationTabs.join(first, among: [main, first])
        #expect(first.tabbedWindows == nil)   // the first one stands alone
        ConversationTabs.join(second, among: [main, first, second])
        #expect(Set((first.tabbedWindows ?? []).map(ObjectIdentifier.init)) == Set([first, second].map(ObjectIdentifier.init)))
        #expect(main.tabbedWindows == nil)   // the main window isn't a conversation tab
    }
    /// Settings ▸ General can turn tabs off: each conversation then opens in a window of its own.
    @Test func withTabsOffEachConversationGetsItsOwnWindow() {
        let first = Self.window(), second = Self.window()
        defer { [first, second].forEach { $0.close() } }
        ConversationTabs.join(first, among: [first], asTab: false)
        ConversationTabs.join(second, among: [first, second], asTab: false)
        #expect(first.tabbedWindows == nil && second.tabbedWindows == nil)
        #expect(second.tabbingIdentifier == ConversationTabs.identifier)   // so Window ▸ Merge All Windows still joins them
    }
}
