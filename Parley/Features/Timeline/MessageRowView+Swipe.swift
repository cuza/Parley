import AppKit

extension MessageRowView {
    static let quoteIcon =
        NSImage(systemSymbolName: "arrowshape.turn.up.left.circle.fill", accessibilityDescription: "Reply") ?? NSImage()
    static let threadIcon =
        NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Reply in Thread")
        ?? NSImage()
    /// Swipe to reply (Telegram's reveal): the content slides left by `-offset` and the reply arrow fades in at the
    /// right edge, fully opaque once a stage is armed; at the thread stage it becomes the thread icon.
    func setSwipe(offset: CGFloat, stage: ReplySwipe.Stage?) {
        let shift = max(0, -offset)
        bounds.origin.x = shift
        let icon = stage == .thread ? Self.threadIcon : Self.quoteIcon
        if replyArrow.image !== icon { replyArrow.image = icon }
        replyArrow.alphaValue = shift == 0 ? 0 : stage != nil ? 1 : min(0.95, shift / ReplySwipe.threshold)
        placeReplyArrow()
    }
    func placeReplyArrow() {
        let size: CGFloat = 26
        replyArrow.frame = NSRect(x: bounds.maxX - size - 10, y: (bounds.height - size) / 2, width: size, height: size)
    }
}
