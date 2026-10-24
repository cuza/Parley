import AppKit
import ParleyDomain
import SwiftUI

/// What a reaction pill's hover card shows, as Google Chat web does: the emoji large, a custom emoji's `:name:`, who reacted.
struct ReactionCardView: View {
    let reaction: Reaction
    var names: String
    let load: (Attachment, Bool) async throws -> Data
    var body: some View {
        VStack(spacing: 4) {
            if let custom = reaction.custom {
                CustomEmojiImage(emoji: custom, size: 40, load: load)
                Text(custom.text).font(.caption.weight(.semibold))
            } else {
                Text(reaction.emoji).font(.system(size: 36))
            }
            if !names.isEmpty {
                Text(names).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(minWidth: 80, maxWidth: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}

/// A reaction pill's hover card: shown once the pointer rests on the pill, updated in place when the names arrive, gone on
/// exit, click or scroll. A borderless child panel that ignores the mouse rather than a popover: it never takes focus,
/// activation or the pill's clicks, and has no arrow or animation for a passing glance.
@MainActor final class ReactionCard {
    static let shared = ReactionCard()
    var delay: Duration = .milliseconds(400)
    private(set) var content: ReactionCardView?
    private(set) var panel: NSPanel?
    private weak var anchor: NSView?
    private var anchorRect: NSRect?  // in the anchor's coordinates: an emoji inside a text view; nil: the whole anchor
    private var pending: Task<Void, Never>?
    private var scrolling: NSObjectProtocol?

    var isShown: Bool { panel?.parent != nil }
    func hover(_ pill: NSView, _ content: ReactionCardView, at rect: NSRect? = nil) {
        hide()
        anchor = pill
        anchorRect = rect
        self.content = content
        pending = Task { [weak self] in
            try? await Task.sleep(for: self?.delay ?? .zero)
            guard !Task.isCancelled else { return }
            self?.show()
        }
    }
    /// New content for `pill`'s card, shown or still waiting; another pill's is ignored.
    func update(_ pill: NSView, _ content: ReactionCardView) {
        guard anchor === pill else { return }
        self.content = content
        if isShown { show() }
    }
    /// Hides the card; with a pill, only that pill's.
    func hide(_ pill: NSView? = nil) {
        if let pill, anchor !== pill { return }
        pending?.cancel()
        pending = nil
        if let scrolling { NotificationCenter.default.removeObserver(scrolling) }
        scrolling = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        anchor = nil
    }
    private func show() {
        guard let anchor, let content, let window = anchor.window else { return hide() }
        let panel =
            self.panel
            ?? {
                let panel = NSPanel(
                    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.ignoresMouseEvents = true
                panel.contentView = NSHostingView(rootView: content)
                self.panel = panel
                return panel
            }()
        guard let host = panel.contentView as? NSHostingView<ReactionCardView> else { return }
        host.rootView = content
        let size = host.fittingSize
        let pill = window.convertToScreen(anchor.convert(anchorRect ?? anchor.bounds, to: nil))
        panel.setFrame(
            NSRect(x: pill.midX - size.width / 2, y: pill.maxY + 6, width: size.width, height: size.height),
            display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if scrolling == nil, let clip = anchor.enclosingScrollView?.contentView {
            scrolling = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }
}
