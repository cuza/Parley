import AppKit
import Foundation
import Testing

@testable import Parley

@MainActor struct ComposerScrollerTests {
    /// With "Show scroll bars: Always" (or a mouse attached) scrollers are legacy and drawn whenever they are shown.
    @Test func theScrollerShowsOnlyWhenTheDraftOverflows() throws {
        let scroll = NativeComposer.makeScrollView(delegate: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 42), styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.scrollerStyle = .legacy
        let view = try #require(scroll.documentView as? ComposerTextView)
        func settle() {
            view.sizeToFit()
            scroll.tile()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        view.load("one line", [])
        settle()
        #expect(scroll.verticalScroller?.isHidden != false, "a scroller shows beside a one-line draft")
        view.load(Array(repeating: "line", count: 20).joined(separator: "\n"), [])
        settle()
        #expect(scroll.verticalScroller?.isHidden == false, "a long draft has no scroller to scroll it with")
        view.load("", [])
        settle()
        #expect(scroll.verticalScroller?.isHidden != false, "a scroller shows beside an empty draft")
    }
}
