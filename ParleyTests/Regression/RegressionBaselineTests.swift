import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// Before-and-after checks for a refactor: the demo workspace's screens, every demo message's row layout, and a scripted
/// run of the store, recorded once and compared after the change. Off in normal runs; set `PARLEY_BASELINE` to a folder
/// (with `TEST_RUNNER_` in front for xcodebuild) to compare against it, and `PARLEY_BASELINE_RECORD=1` to record it.
/// Run it on its own (`-only-testing:ParleyTests/RegressionBaselineTests`): other suites change shared settings such as
/// the side pane's width while it renders.
@MainActor @Suite(.serialized, .enabled(if: RegressionBaseline.folder != nil)) struct RegressionBaselineTests {
    /// The demo's screens as the main window shows them, in light mode at a fixed size.
    @Test(arguments: RegressionBaseline.Screen.allCases) func screen(_ screen: RegressionBaseline.Screen) async throws {
        UserDefaults.standard.removeObject(forKey: "sidePaneWidth")  // a dragged width from another run or test
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await screen.setUp(store)
        let image = try await RegressionBaseline.render(
            ChatView().environment(store), size: NSSize(width: 1100, height: 700))
        try RegressionBaseline.compare(image: image, named: "screen-\(screen.rawValue)")
    }
    /// Every demo conversation's rows, laid out at two widths, with message times pinned so the clock doesn't matter.
    @Test func rowLayouts() async throws {
        var lines: [String] = []
        let demos: [(String, FakeBackend)] = [
            ("demo", FakeBackend()), ("formatted", FakeBackend(formattedThread: true)),
            ("long", FakeBackend(longHistory: 60)),
        ]
        for (label, backend) in demos {
            let store = ChatStore(backend: backend)
            await store.start()
            for conversation in store.rooms.conversations.sorted(by: { $0.id < $1.id }) {
                await store.select(conversation.id)
                let threads = Dictionary(
                    grouping: store.history.messages.filter { $0.conversationID == conversation.id }, by: \.threadID)
                for (thread, messages) in threads.sorted(by: { ($0.key ?? "") < ($1.key ?? "") }) {
                    let base = Date(timeIntervalSince1970: 1_790_000_000)
                    let pinned = messages.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }.enumerated().map {
                        offset, message in
                        var message = message
                        message.createdAt = base.addingTimeInterval(Double(offset) * 60)
                        return message
                    }
                    for (offset, row) in TimelineRow.rows(pinned).enumerated() {
                        for width in [CGFloat(640), 420] {
                            let layout = RowLayout.make(
                                row, width: width, own: row.message.sender.id == store.me.id, kind: conversation.kind)
                            lines.append(
                                "\(label) \(conversation.id)/\(thread ?? "-")#\(offset)@\(Int(width)): \(layout)")
                        }
                    }
                }
            }
        }
        try RegressionBaseline.compare(text: lines.joined(separator: "\n"), named: "row-layouts")
    }
    /// A scripted session: send, react, star, pin, draft, a thread reply, search. The store's state after it, without
    /// timestamps or new ids.
    @Test func storeScript() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let seeded = Set(store.history.messages.map(\.id.rawValue))  // thread ids are their heads' ids
        await store.select("design")
        store.setDraft("Hello from the baseline", conversation: "design", thread: nil)
        await store.send(conversation: "design")
        let target = try #require(
            store.history.messages.filter { $0.conversationID == "design" && $0.sender.id != store.me.id }
                .sorted { $0.createdAt < $1.createdAt }.last)
        await store.react("👍", to: target)
        await store.setStarred(true, target)
        await store.setSidebarPinned(true, "alex")
        await store.select("maria")
        store.setDraft("A draft that stays", conversation: "maria", thread: nil)
        await store.openThread(target)
        let thread = target.threadID ?? ThreadID(head: target.id)
        store.setDraft("A reply in the thread", conversation: "design", thread: thread)
        await store.send(conversation: "design", thread: thread)
        await store.search("launch")
        await store.select("general")
        try? await Task.sleep(for: .milliseconds(300))  // sends and reactions settle

        func id(_ value: String?) -> String { value.map { seeded.contains($0) ? $0 : "new" } ?? "-" }
        var lines = store.rooms.conversations.sorted { $0.id < $1.id }.map {
            "conversation \($0.id) \($0.name) \($0.kind) unread=\($0.unread) pinned=\($0.pinned) muted=\($0.muted) hidden=\($0.hidden != nil)"
        }
        lines += store.history.messages.map {
            let reactions = $0.reactions.map { "\($0.emoji)x\($0.people.count)" }.sorted().joined(separator: ",")
            return
                "message \($0.conversationID) thread=\(id($0.threadID?.rawValue)) id=\(id($0.id.rawValue)) from=\($0.sender.id) \($0.delivery) "
                + "starred=\($0.starred) reactions=[\(reactions)] attachments=\($0.attachments.map { "\($0.kind)" }) \($0.text)"
        }.sorted()
        lines += store.drafting.text.filter { !$0.value.isEmpty }.map { "draft \($0.key) \($0.value)" }.sorted()
        lines.append(
            "selected \(store.navigation.selectedID ?? "-") thread=\(id(store.navigation.threadID?.rawValue)) info=\(store.navigation.pane(nil).info) search=\(store.searchResults.count)"
        )
        try RegressionBaseline.compare(text: lines.joined(separator: "\n"), named: "store-script")
    }
}

@MainActor enum RegressionBaseline {
    nonisolated static var folder: URL? {
        ProcessInfo.processInfo.environment["PARLEY_BASELINE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var recording: Bool { ProcessInfo.processInfo.environment["PARLEY_BASELINE_RECORD"] == "1" }

    enum Screen: String, CaseIterable, Sendable {
        case space, directMessage, thread, info, personDetails, home, draft
        @MainActor func setUp(_ store: ChatStore) async {
            switch self {
            case .space: await store.select("design")
            case .directMessage: await store.select("maria")
            case .thread:
                await store.select("design")
                if let message = store.history.messages.first(where: {
                    $0.conversationID == "design" && $0.replyCount > 0
                }) {
                    await store.openThread(message)
                }
            case .info:
                await store.select("design")
                store.toggleInfo()
            case .personDetails:
                await store.select("design")
                if let maria = store.rooms.conversations.first(where: { $0.id == "maria" })?.members.first(where: {
                    $0.id == "maria"
                }) {
                    store.showDetails(maria)
                }
            case .home: store.navigation.shortcut = .home
            case .draft:
                await store.select("general")
                store.setDraft(
                    "Bold and a chip", formatting: [TextStyleRange(style: .bold, start: 0, length: 4)],
                    conversation: "general", thread: nil)
            }
        }
    }

    static func render(_ view: some View, size: NSSize) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        // Overlay scroll bars, as with a trackpad, whatever is attached: a mouse's always-visible ones narrow the timeline.
        func overlay(_ view: NSView) {
            (view as? NSScrollView)?.scrollerStyle = .overlay
            view.subviews.forEach(overlay)
        }
        for _ in 0..<8 {
            overlay(host)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Pixels that differ by more than a few levels in any channel; up to 1% may differ (clock-driven time labels).
    static func compare(image: NSBitmapImageRep, named name: String) throws {
        let folder = try #require(folder)
        let url = folder.appending(path: name + ".png")
        let png = try #require(image.representation(using: .png, properties: [:]))
        if recording {
            try png.write(to: url)
            return
        }
        let saved = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)), "no baseline \(name); record first")
        let current = try #require(NSBitmapImageRep(data: png))
        try png.write(to: folder.appending(path: name + ".current.png"))
        #expect(
            saved.pixelsWide == current.pixelsWide && saved.pixelsHigh == current.pixelsHigh, "\(name): size changed")
        guard saved.pixelsWide == current.pixelsWide, saved.pixelsHigh == current.pixelsHigh else { return }
        var differing = 0
        for row in 0..<current.pixelsHigh {
            for column in 0..<current.pixelsWide {
                guard let before = saved.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
                    let after = current.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)
                else { continue }
                let delta = max(
                    abs(before.redComponent - after.redComponent), abs(before.greenComponent - after.greenComponent),
                    abs(before.blueComponent - after.blueComponent))
                if delta > 0.04 { differing += 1 }
            }
        }
        let share = Double(differing) / Double(current.pixelsWide * current.pixelsHigh)
        #expect(
            share <= 0.01, "\(name): \(String(format: "%.2f", share * 100))% of pixels differ; see \(name).current.png")
    }

    static func compare(text: String, named name: String) throws {
        let folder = try #require(folder)
        let url = folder.appending(path: name + ".txt")
        if recording {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let saved = try String(contentsOf: url, encoding: .utf8)
        try text.write(to: folder.appending(path: name + ".current.txt"), atomically: true, encoding: .utf8)
        let before = saved.split(separator: "\n", omittingEmptySubsequences: false)
        let after = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = (0..<min(before.count, after.count)).first { before[$0] != after[$0] }
        #expect(
            saved == text,
            Comment(
                rawValue: "\(name): \(before.count) lines before, \(after.count) after; first difference at line "
                    + "\((first ?? min(before.count, after.count)) + 1): \(first.map { "\(before[$0]) → \(after[$0])" } ?? "")"
            ))
    }
}
