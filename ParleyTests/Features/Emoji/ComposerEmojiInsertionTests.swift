import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct ComposerEmojiInsertionTests {
    private final class Changes: NSObject, NSTextViewDelegate {
        var drafts: [String] = []
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? ComposerTextView { drafts.append(view.string) }
        }
    }
    private struct Composer {
        let handle: ComposerHandle, view: ComposerTextView, window: NSWindow, changes: Changes
    }
    private func composer() throws -> Composer {
        let changes = Changes()
        let scroll = NativeComposer.makeScrollView(delegate: changes)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 42), styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        let view = try #require(scroll.documentView as? ComposerTextView)
        let name = "ComposerEmojiInsertionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let handle = ComposerHandle(usage: EmojiUsage(defaults: defaults))
        handle.view = view
        return Composer(handle: handle, view: view, window: window, changes: changes)
    }
    @Test func aPickedEmojiGoesInAtTheCaretAndLaterFormattingMovesWithTheText() throws {
        let made = try composer()
        let (handle, view, window, changes) = (made.handle, made.view, made.window, made.changes)
        view.load("hi there", [TextStyleRange(style: .bold, start: 3, length: 5)])
        view.setSelectedRange(NSRange(location: 2, length: 0))
        window.makeFirstResponder(nil)  // the picker had the focus
        var closed = false
        handle.emojiPicker(close: { closed = true }).pick("🦊")
        #expect(view.string == "hi🦊 there")
        #expect(view.formatting == [TextStyleRange(style: .bold, start: 5, length: 5)])  // 🦊 is two UTF-16 units
        #expect(view.selectedRange() == NSRange(location: 4, length: 0))
        #expect(changes.drafts.last == "hi🦊 there")  // the store hears of it
        #expect(handle.usage.top(1) == ["🦊"])
        #expect(closed)
        #expect(window.firstResponder === view)
    }
    @Test func aPickedEmojiReplacesTheSelection() throws {
        let made = try composer()
        let (handle, view) = (made.handle, made.view)
        view.load("hi there you", [TextStyleRange(style: .italic, start: 9, length: 3)])
        view.setSelectedRange(NSRange(location: 3, length: 5))  // "there"
        handle.emojiPicker(close: {}).pick("👋")
        #expect(view.string == "hi 👋 you")
        #expect(view.formatting == [TextStyleRange(style: .italic, start: 6, length: 3)])
    }
    @Test func thePickerOffersTheMostUsedFirst() throws {
        let handle = try composer().handle
        handle.usage.record("🦊")
        #expect(handle.emojiPicker(close: {}).frequent.first == "🦊")
    }
}
