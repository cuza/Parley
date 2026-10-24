import ParleyDomain
import SwiftUI

extension ChatLink {
    /// Copy Link and Copy Message Link: the link alone, as plain text.
    @MainActor static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
    /// Shows web's card for a conversation this account can't open (`RestrictedCard`) above `rect` (screen coordinates,
    /// taken at the click), as the emoji hover card shows: a panel placed once, which a row's reused views can't move.
    /// The next click, key or scroll closes it.
    @MainActor static func showRestricted(_ link: ChatLink, above rect: NSRect, in window: NSWindow) {
        RestrictedPanel.shared.show(RestrictedCard(title: link.restrictedTitle), above: rect, in: window)
    }
}

@MainActor private final class RestrictedPanel {
    static let shared = RestrictedPanel()
    private var panel: NSPanel?
    private var monitor: Any?
    func show(_ card: RestrictedCard, above rect: NSRect, in window: NSWindow) {
        hide()
        let host = NSHostingView(rootView: card)
        let size = host.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(
                x: rect.midX - size.width / 2, y: rect.maxY + 6, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel])
        { [weak self] event in
            self?.hide()
            return event
        }
    }
    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }
}

/// As Google Chat's web card for a space the account can't see: a lock, "Restricted space", and why.
struct RestrictedCard: View {
    let title: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock").font(.title2).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text("Not in this account: you may not be a member, or it belongs to another Google account.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}
