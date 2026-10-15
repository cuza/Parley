import AppKit
import SwiftUI
import Testing
@testable import Parley

/// The info panel of a large space opens without building every member row up front.
@MainActor struct InfoPanelPerformanceTests {
    private func openTime(members count: Int) async -> Duration {
        let people = (0..<count).map { Person(id: "p\($0)", name: "Person \($0)", avatarURL: URL(string: "https://lh3.googleusercontent.com/a/p\($0)"),
                                              email: "p\($0)@example.com") }
        let room = Conversation(id: "space/big", name: "Big space", kind: .space, members: people)
        let store = ChatStore(backend: FakeBackend())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it; close() must not release it too
        let started = ContinuousClock.now
        let host = NSHostingView(rootView: InfoPanel(store: store, room: room, search: nil))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        let took = ContinuousClock.now - started
        window.close()
        return took
    }
    @Test func aLargeSpaceOpensAsFastAsASmallOne() async {
        _ = await openTime(members: 5)   // warm up
        let small = await openTime(members: 10), large = await openTime(members: 300)
        print("info panel open: 10 members \(small), 300 members \(large)")
        #expect(large < small * 3, "300 members took \(large), 10 took \(small)")
    }
}
