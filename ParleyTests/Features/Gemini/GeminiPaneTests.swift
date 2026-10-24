import AppKit
import SwiftUI
import Testing

@testable import Parley

/// Ask Gemini's home greets by time of day and first name, as web Chat does.
struct GeminiPaneTests {
    static func at(_ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: 30))!
    }
    @Test func theGreetingFollowsTheTimeOfDay() {
        #expect(GeminiPane.greeting(name: "Dave Moreno", at: Self.at(9)) == "Good morning, Dave")
        #expect(GeminiPane.greeting(name: "Dave Moreno", at: Self.at(14)) == "Good afternoon, Dave")
        #expect(GeminiPane.greeting(name: "Dave Moreno", at: Self.at(20)) == "Good evening, Dave")
        #expect(GeminiPane.greeting(name: "", at: Self.at(20)) == "Good evening")
    }
    /// The home's scroll view spans the pane. A scroll view only as wide as the session list drew its edge under the
    /// toolbar as a box that lit up on hover, on macOS 26 and later.
    @MainActor @Test func theHomeScrollsAcrossThePane() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.rooms.conversations.first { $0.app == .gemini })
        let host = NSHostingView(rootView: GeminiPane(room: room).environment(store).frame(width: 900, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
        }
        let widths = scrolls(host).map(\.frame.width)
        #expect(widths.contains { $0 >= 899 }, "scroll view widths: \(widths)")
    }
}
