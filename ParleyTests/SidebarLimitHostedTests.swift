import AppKit
import SwiftUI
import Testing
@testable import Parley

/// The sidebar as the window shows it, over 80 extra DMs and spaces: with Limit sidebar sections on, each long section
/// shows its first rows and a "Show all" row; "Show all" lists the rest. Off, it lists everything as before.
@MainActor @Suite(.serialized) struct SidebarLimitHostedTests {
    private static let keys = [SidebarLimit.enabledKey, SidebarLimit.countKey, SidebarLimit.expandedKey, "collapsedSidebarSections"]
    private func rows(enabled: Bool, expanded: String = "") async throws -> (rows: Int, store: ChatStore) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: SidebarLimit.enabledKey)
        defaults.set(10, forKey: SidebarLimit.countKey)
        defaults.set(expanded, forKey: SidebarLimit.expandedKey)
        defaults.removeObject(forKey: "collapsedSidebarSections")
        let store = ChatStore(backend: FakeBackend(manyConversations: 80))
        await store.start()
        let host = NSHostingView(rootView: ChatView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(100)) }
        func outlines(_ view: NSView) -> [NSOutlineView] { (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines) }
        let sidebar = try #require(outlines(host).first)
        return (sidebar.numberOfRows, store)
    }
    @Test func longSectionsAreCappedBehindShowAll() async throws {
        let saved = Self.keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(Self.keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let (all, store) = try await rows(enabled: false)
        let sections = Conversation.sidebarSections(store.conversations, limit: 10, selected: store.selectedID)
        let hidden = sections.map(\.hidden.count).reduce(0, +)
        let capped = sections.filter { !$0.hidden.isEmpty }.count
        #expect(hidden > 20 && capped == 2)   // Direct messages and Spaces
        let limited = try await rows(enabled: true).rows
        #expect(limited == all - hidden + capped)   // a "Show all" row in each capped section
        #expect(limited < 50)
        let open = try await rows(enabled: true, expanded: "Direct messages\nSpaces").rows
        #expect(open == all + capped)   // everything, and "Show less"
    }
}
