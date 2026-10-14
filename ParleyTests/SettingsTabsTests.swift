import AppKit
import SwiftUI
import Testing
@testable import Parley

/// Settings as macOS tabs of grouped forms: each tab hosted at the fixed width shows all its content without scrolling,
/// keeps every caption inside the form's margins, and Hidden conversations' list starts at the top of its section.
@MainActor struct SettingsTabsTests {
    private func hosted(_ tab: SettingsTab, _ store: ChatStore) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: SettingsView.page(tab, store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }
    /// A store with many hidden conversations: the longest the General tab gets.
    private func started() async -> ChatStore {
        let store = ChatStore(backend: FakeBackend(manyConversations: 40))
        await store.start()
        for id in store.conversations.prefix(30).map(\.id) { await store.hide(id) }
        return store
    }
    private func subviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(subviews) }
    private func snapshot(_ host: NSView) throws -> (NSBitmapImageRep, CGFloat) {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / host.bounds.width)
    }
    /// Whether two pixels differ visibly (the hosting view is flipped: y grows down, as bitmap rows do).
    private func differ(_ rep: NSBitmapImageRep, _ a: (Int, Int), _ b: (Int, Int), by threshold: CGFloat = 0.15) -> Bool {
        guard let c = rep.colorAt(x: a.0, y: a.1)?.usingColorSpace(.deviceRGB),
              let d = rep.colorAt(x: b.0, y: b.1)?.usingColorSpace(.deviceRGB) else { return false }
        return abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent) + abs(c.blueComponent - d.blueComponent) > threshold
    }

    @Test func eachTabFitsItsContentAtTheFixedWidth() async throws {
        let store = await started()
        for tab in SettingsTab.allCases {
            let host = hosted(tab, store)
            let size = host.fittingSize
            #expect(abs(size.width - SettingsTab.width) < 0.5, "\(tab) width \(size.width)")
            // Each tab's window is as tall as its content: it must still fit the smallest Mac screen (about 830 pt usable).
            #expect(size.height > 80 && size.height <= 700, "\(tab) height \(size.height)")
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            // The grouped form's own scroll view spans the page and shows everything: nothing hides below the window.
            let form = try #require(subviews(host).compactMap { $0 as? NSScrollView }.first { abs($0.frame.width - SettingsTab.width) < 0.5 },
                                    "\(tab) is not a grouped form")
            let document = try #require(form.documentView)
            #expect(document.frame.height <= form.contentView.bounds.height + 1,
                    "\(tab) scrolls: \(document.frame.height) in \(form.contentView.bounds.height)")
        }
    }

    /// Nothing is drawn in the form's right margin: every caption wraps before the sections' edge.
    @Test func captionsStayInsideTheMargins() async throws {
        let store = await started()
        for tab in SettingsTab.allCases {
            let host = hosted(tab, store)
            host.setFrameSize(host.fittingSize)   // the page fills the host, as it fills the settings window
            host.layoutSubtreeIfNeeded()
            let (rep, scale) = try snapshot(host)
            var overflow: CGFloat?
            rows: for y in stride(from: scale, to: (host.bounds.height - 1) * scale, by: 1) {
                for x in stride(from: (host.bounds.width - 16) * scale, to: host.bounds.width * scale, by: 1)
                where differ(rep, (Int(x), Int(y)), (Int(2 * scale), Int(y))) {
                    overflow = y / scale
                    break rows
                }
            }
            #expect(overflow == nil, "\(tab) draws in the right margin at y \(overflow ?? 0)")
        }
    }

    /// Hidden conversations' list starts at the top of its section, not centred or dropped in a taller row.
    @Test func hiddenConversationsListSitsAtTheTopOfItsSection() async throws {
        let store = await started()
        let host = hosted(.general, store)
        let list = try #require(subviews(host).compactMap { $0 as? NSScrollView }.min { $0.frame.height < $1.frame.height })
        let frame = list.convert(list.bounds, to: host)
        #expect(host.isFlipped && frame.height > 100)
        let (rep, scale) = try snapshot(host)
        let x = Int((frame.minX + 2) * scale), start = Int((frame.minY - 1) * scale)
        // Up from the list: the section's own background, then its edge (or the header) within a row's padding.
        let edge = stride(from: start, to: 0, by: -1).first { differ(rep, (x, $0), (x, start), by: 0.05) } ?? 0
        #expect(CGFloat(start - edge) / scale <= 16, "list \(CGFloat(start - edge) / scale) pt below its section's top")
    }
}
