import AppKit
import Foundation
import SwiftUI
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

/// The composer as the bar sizes it: as tall as the text it reports, up to 130 points.
private struct GrowingField: View {
    let text: String
    let reported: (CGFloat) -> Void
    @State private var height: CGFloat = 0
    var body: some View {
        NativeComposer(
            text: text, change: { _, _ in }, send: {}, editLast: {}, cancel: {},
            height: {
                reported($0)
                if height != $0 { height = $0 }
            }
        ).frame(height: min(NativeComposer.tallest, max(42, height)))
    }
}

@MainActor struct ComposerScrollerLoopTests {
    /// A legacy scroller narrows the text. In a narrow thread panel that rewrapped the draft taller, the field grew, the
    /// scroller hid, the text rewrapped shorter, the field shrank and the scroller came back, many times a second.
    @Test(arguments: Array(stride(from: 60, through: 140, by: 4)))
    func aLegacyScrollerDoesNotMakeTheFieldBounce(width: Int) async throws {
        var reports = 0
        let host = NSHostingView(rootView: GrowingField(text: "Hay cosas de tu rediseño que no") { _ in reports += 1 })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [], backing: .buffered,
            defer: false)
        window.contentView = host
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        for _ in 0..<5 {  // the scroll view appears once SwiftUI has laid the host out
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let scroll = try #require(scrollViews(host).first)
        scroll.scrollerStyle = .legacy
        reports = 0
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reports <= 4, "the field changed height \(reports) times at width \(width)")
    }
}
