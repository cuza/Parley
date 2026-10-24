import AppKit
import ParleyDomain
import SwiftUI

struct NativeMessageText: NSViewRepresentable {
    let text: String
    var formatting: [TextStyleRange] = []
    var quote: QuotedMessage?
    let own: Bool
    /// 0: all of it. Otherwise that many lines ending in "…", and clicks pass through to the view behind (to expand it).
    var lines = 0
    var maxWidth: CGFloat = 440
    /// Changed when a custom emoji's picture arrives, so the text draws it.
    var redraw = 0
    final class TextView: NSTextView {
        var passesClicks = false
        override func hitTest(_ point: NSPoint) -> NSView? { passesClicks ? nil : super.hitTest(point) }
    }
    func makeNSView(context: Context) -> TextView {
        let view = TextView(usingTextLayoutManager: false)  // TextKit 1, like `size(of:width:)`, so measured and drawn wrapping agree
        view.textContainer?.replaceLayoutManager(MessageLayoutManager())  // quote bars, code backgrounds, rounded pills
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        return view
    }
    func updateNSView(_ view: TextView, context: Context) {
        Self.show(text, formatting: formatting, quote: quote, own: own, in: view)
        view.textContainer?.maximumNumberOfLines = lines
        view.textContainer?.lineBreakMode = lines > 0 ? .byTruncatingTail : .byWordWrapping
        view.passesClicks = lines > 0
        view.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        let width = min(proposal.width ?? 440, maxWidth)
        let size = Self.size(of: text, formatting: formatting, quote: quote, width: width, lines: lines)
        // Lay out at the width just measured, not one the text view's frame may still carry from a wider layout: a
        // narrowed card otherwise drew its text past its edge.
        if let container = nsView.textContainer, container.size.width != size.width {
            container.size = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        }
        return size
    }
    /// Restyles only real changes: SwiftUI updates rows often, and a reset clears the reader's selection and redoes link detection.
    static func show(
        _ text: String, formatting: [TextStyleRange] = [], quote: QuotedMessage? = nil, own: Bool, jumbo: Int? = nil,
        in view: NSTextView,
        scale: CGFloat = TextSize.scale
    ) {
        let key = "\(scale)\u{2}" + MessageTextStyle.key(text, formatting, quote, own, jumbo: jumbo)  // a new text size shows again
        guard objc_getAssociatedObject(view, &shownKey) as? String != key else { return }
        view.textStorage?.setAttributedString(
            MessageTextStyle.styled(text, formatting, quote, own: own, jumbo: jumbo, scale: scale))
        objc_setAssociatedObject(view, &shownKey, key, .OBJC_ASSOCIATION_COPY_NONATOMIC)
    }
    /// Cached per styled content and width: the lazy stack re-measures rows on every scroll pass.
    /// Nonisolated, as `MessageTextStyle` is: card layouts are measured with the rows, off the main actor too.
    nonisolated static func size(
        of text: String, formatting: [TextStyleRange] = [], quote: QuotedMessage? = nil, width: CGFloat, lines: Int = 0
    ) -> CGSize {
        let key =
            "\(width)\u{0}\(lines)\u{0}\(TextSize.scale)\u{0}\(MessageTextStyle.key(text, formatting, quote, false))"
            as NSString
        if let cached = sizes.object(forKey: key) { return cached.sizeValue }
        let used = MessageTextStyle.measure(
            MessageTextStyle.styled(text, formatting, quote, own: false), width: width, lines: lines
        ).size
        let size = CGSize(width: min(width, max(20, used.width)), height: max(18, used.height))
        sizes.setObject(NSValue(size: size), forKey: key)
        return size
    }
    private static var shownKey: UInt8 = 0
    nonisolated(unsafe) private static let sizes = NSCache<NSString, NSValue>()  // NSCache is thread-safe
}
