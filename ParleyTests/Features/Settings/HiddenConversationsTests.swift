import AppKit
import SwiftUI
import Testing

@testable import Parley

/// Settings ▸ Hidden conversations, hosted at Settings' width: one row per hidden conversation (long names cut, not
/// widening Settings), the list scrolling past a few rows, and a one-line empty state.
@MainActor struct HiddenConversationsTests {
    /// The section in a grouped form at Settings' width: the form's size, and the list's height when there is one.
    private func size(_ store: ChatStore) -> (form: CGSize, list: CGFloat?) {
        let form = Form { HiddenConversationsSection().environment(store) }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true).frame(width: 380)
        let host = NSHostingView(rootView: form)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func scrolls(_ view: NSView) -> [NSScrollView] {
            view.subviews.compactMap { $0 as? NSScrollView } + view.subviews.flatMap(scrolls)
        }
        let list = scrolls(host).filter { $0.frame.width < 379 }.map(\.frame.height).min()  // the form's own spans the width
        return (host.fittingSize, list)
    }
    private func started(many: Int = 0) async -> ChatStore {
        let store = ChatStore(backend: FakeBackend(manyConversations: many))
        await store.start()
        return store
    }

    @Test func growsWithTheListThenScrolls() async {
        let empty = size(await started())
        #expect(empty.form.width <= 380.5 && empty.list == nil)  // "No hidden conversations", no list
        let store = await started(many: 40)
        for id in store.rooms.conversations.prefix(2).map(\.id) { await store.hide(id) }
        let two = size(store)
        #expect(store.rooms.hidden.count == 2 && two.form.width <= 380.5 && two.form.height > empty.form.height)
        for id in store.rooms.conversations.prefix(30).map(\.id) { await store.hide(id) }
        let many = size(store)
        #expect(store.rooms.hidden.count == 32 && many.form.width <= 380.5)
        #expect((many.list ?? 0) > (two.list ?? 0) && (many.list ?? .infinity) <= 160.5)
    }
}
