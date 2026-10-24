import AppKit
import Testing

@testable import Parley

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
