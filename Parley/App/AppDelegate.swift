import AppKit
import ParleyDomain

/// Quitting waits (up to 3 s) for the drafts to reach Google; unsaved ones are also kept for the next launch.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var beforeQuit: (() -> Task<Void, Never>)?
    var dockMenu: (() -> NSMenu)?
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { dockMenu?() }
    let shareService = ShareService()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = shareService
        // The emoji catalog walks ~130,000 code points: build it now, in the background, not on the first `:` typed.
        Task.detached(priority: .utility) { _ = EmojiCatalog.categories }
    }
    /// Links sent to Parley; ones that arrive before the window (the link launched Parley) wait for it.
    var openURL: ((URL) -> Void)? {
        didSet {
            if let openURL {
                waitingURLs.forEach(openURL)
                waitingURLs = []
            }
        }
    }
    private var waitingURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate()
        if let openURL { urls.forEach(openURL) } else { waitingURLs += urls }
    }
    private var replied = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let save = beforeQuit?() else { return .terminateNow }
        replied = false
        Task {
            await save.value
            reply(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            reply(sender)
        }
        return .terminateLater
    }
    private func reply(_ app: NSApplication) {
        guard !replied else { return }
        replied = true
        app.reply(toApplicationShouldTerminate: true)
    }
}

/// The Dock icon's menu: unread conversations with their counts, then Mark All as Read.
@MainActor enum DockMenu {
    static func make(
        _ conversations: [Conversation], open: @escaping (ConversationID) -> Void, markAllRead: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        for room in conversations {
            let item = ClosureMenuItem(room.name) { open(room.id) }
            item.badge = NSMenuItemBadge(count: room.unread)
            menu.addItem(item)
        }
        if !conversations.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("Mark All as Read") { markAllRead() })
        return menu
    }
}
