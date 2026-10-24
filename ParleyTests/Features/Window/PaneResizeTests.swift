import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// Dragging the main window's dividers: the sidebar stops at its maximum and never squeezes the timeline, and the
/// side pane resizes within its bounds. Serialized, with Home's pane test here too: they set the pane's saved width
/// (`sidePaneWidth`), which every side pane reads.
@MainActor @Suite(.serialized) struct PaneResizeTests {
    private func hosted(width: CGFloat = 1000) async -> (ChatStore, NSHostingView<some View>, NSWindow) {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let host = NSHostingView(rootView: ChatView().environment(store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await settle(host, window)
        return (store, host, window)
    }
    private func settle(_ host: NSView, _ window: NSWindow) async {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    private func splits(_ view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
    }

    private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }
    private func timeline(in host: NSView) -> NSTableView? {
        tables(in: host).filter { $0.numberOfRows > 0 }.max { $0.bounds.width < $1.bounds.width }
    }

    @Test func theSidebarStopsAtItsMaximum() async throws {
        let (_, host, window) = await hosted()
        defer { window.close() }
        let split = try #require(splits(host).first)
        #expect(split.arrangedSubviews[0].frame.width == 230)  // its ideal width, not the split view's default
        split.setPosition(800, ofDividerAt: 0)
        await settle(host, window)
        #expect(split.arrangedSubviews[0].frame.width == ChatView.sidebarMaxWidth)
        #expect(split.convert(split.bounds, to: nil).maxX <= host.bounds.width)
    }
    /// With a pane open in a window just wide enough, widening the sidebar must not push the pane off the right edge.
    @Test func aWiderSidebarNeverSqueezesTheTimelineAndPane() async throws {
        let saved = UserDefaults.standard.object(forKey: "sidePaneWidth")  // the user's own dragged width
        UserDefaults.standard.removeObject(forKey: "sidePaneWidth")
        defer { UserDefaults.standard.set(saved, forKey: "sidePaneWidth") }
        let (store, host, window) = await hosted()
        defer { window.close() }
        store.navigation.setPane(nil) { $0.content = .info }
        let split = try #require(splits(host).first)
        split.setPosition(ChatView.sidebarMinWidth, ofDividerAt: 0)
        window.setContentSize(
            NSSize(width: ChatView.minWidth(paneOpen: true, sidebar: ChatView.sidebarMinWidth) + 10, height: 650))
        await settle(host, window)
        split.setPosition(ChatView.sidebarMaxWidth, ofDividerAt: 0)
        // The window makes room over a few layout passes, which a busy Mac spreads out.
        await eventually(timeout: .seconds(10)) {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let frame = split.convert(split.bounds, to: nil)
            return frame.minX >= 0 && frame.maxX <= host.bounds.width
        }
        let frame = split.convert(split.bounds, to: nil)
        #expect(frame.minX >= 0 && frame.maxX <= host.bounds.width, "\(frame) in \(host.bounds.width)")
    }
    @Test func thePaneTakesTheWidthItWasDraggedTo() async throws {
        let saved = UserDefaults.standard.object(forKey: "sidePaneWidth")
        UserDefaults.standard.set(480.0, forKey: "sidePaneWidth")
        defer { UserDefaults.standard.set(saved, forKey: "sidePaneWidth") }
        let (store, host, window) = await hosted(width: 1300)
        defer { window.close() }
        store.navigation.setPane(nil) { $0.content = .info }
        func edge() -> CGFloat? { timeline(in: host).map { $0.convert($0.bounds, to: nil).maxX } }
        await eventually(timeout: .seconds(10)) {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return edge().map { abs($0 - (host.bounds.width - 481)) <= 20 } == true
        }
        let end = try #require(edge())
        #expect(abs(end - (host.bounds.width - 481)) <= 20, "timeline ends at \(end) in \(host.bounds.width)")
    }
    /// Home beside an open thread: the pane takes its default width and Home's list keeps the rest.
    @Test func homeKeepsItsListBesideAnOpenThreadPane() async throws {
        let saved = UserDefaults.standard.object(forKey: "sidePaneWidth")  // the user's own dragged width
        UserDefaults.standard.removeObject(forKey: "sidePaneWidth")
        defer { UserDefaults.standard.set(saved, forKey: "sidePaneWidth") }
        let (store, _) = await started(shortcut: .home)
        let thread = try #require(store.homeRows().compactMap(\.thread).first)
        await store.openHomeThread(thread)
        let host = NSHostingView(rootView: HomePane().environment(store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }
        let shown = tables(in: host)
        let list = try #require(shown.first { $0.numberOfRows == store.homeRows().count })
        #expect(list.frame.width >= 900 - ChatView.paneWidth - 60)
        // The thread pane's own timeline sits to the right of the list.
        let pane = try #require(shown.first { $0 !== list })
        #expect(pane.convert(pane.bounds, to: host).minX >= list.convert(list.bounds, to: host).maxX)
        store.navigation.setPane(nil) { $0.closeThread() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(tables(in: host).count == 1)
    }
    @Test func thePaneStaysWithinItsBoundsAndLeavesTheTimelineItsMinimum() {
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 320, room: 0) == ChatView.paneWidth)  // not measured yet
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 100, room: 1400) == ChatView.paneWidth)
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 450, room: 1400) == 450)
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 2000, room: 1400) == ChatView.paneMaxWidth)
        // A narrower window narrows the pane first, down to its minimum.
        #expect(
            SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 500, room: 800) == 800 - ChatView.timelineMinWidth - 1)
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 500, room: 600) == ChatView.paneWidth)
    }
}

/// Which side panes take room beside the timeline: Info, an open thread, and the threads list where a conversation has
/// threads. Each one widens the window's minimum, so it can't be squeezed until the timeline or the pane is cut off.
@MainActor struct SidePaneRoomTests {
    @Test func theThreadsListTakesRoomToo() {
        let dm = Conversation.fixture("dm", kind: .direct, name: "Alex")
        var app = dm
        app.app = .bot
        #expect(ChatView.paneShown(SidePane(threads: true), room: dm))
        #expect(!ChatView.paneShown(SidePane(threads: true), room: app))  // a DM with an app has no threads list
        #expect(ChatView.paneShown(SidePane(content: .info), room: app))
        #expect(ChatView.paneShown(SidePane(content: .thread("t")), room: nil))
        #expect(!ChatView.paneShown(SidePane(), room: dm))
    }
}
