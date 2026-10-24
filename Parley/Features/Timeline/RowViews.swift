import AppKit
import SwiftUI

/// The bubble: a shape layer with a rounded body and, on a run's last bubble, a tail curving out of the bottom corner
/// on the sender's side (the shape of Telegram's bubble images, drawn as a path).
final class BubbleView: NSView {
    var own = false { didSet { if own != oldValue { refresh() } } }
    var fill = NSColor.controlAccentColor { didSet { if fill != oldValue { refresh() } } }
    var tail = false { didSet { if tail != oldValue { refresh() } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks reach the row (its menu) and the text
    // The shape is set directly: AppKit does not call updateLayer() for these views inside table rows.
    override func layout() {
        super.layout()
        refresh()
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        refresh()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
    private func refresh() {
        guard let layer = layer as? CAShapeLayer else { return }
        CATransaction.withoutAnimation {
            layer.path = Self.path(size: bounds.size, tail: tail, mirrored: own)
            effectiveAppearance.performAsCurrentDrawingAppearance {  // resolve dynamic colours for light/dark
                layer.fillColor = fill.cgColor  // BubblePalette's
                // Increase Contrast: an outline, so a pale incoming bubble doesn't melt into a light background.
                let outlined = !own && fill != .clear && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                layer.strokeColor = outlined ? NSColor.separatorColor.cgColor : nil
                layer.lineWidth = outlined ? 1 : 0
            }
        }
    }
    /// In layer coordinates (origin bottom-left). The body leaves `tailWidth` free on the left; `mirrored` puts it on the right.
    static func path(size: CGSize, tail: Bool, mirrored: Bool) -> CGPath {
        let tailWidth = RowLayout.tailWidth
        let width = size.width
        let height = size.height
        let radius = min(RowLayout.cornerRadius, (width - tailWidth) / 2, height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: tailWidth + radius, y: height))
        path.addArc(tangent1End: CGPoint(x: width, y: height), tangent2End: CGPoint(x: width, y: 0), radius: radius)
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: tailWidth, y: 0), radius: radius)
        if tail {
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addCurve(
                to: CGPoint(x: tailWidth, y: min(12, height - radius)), control1: CGPoint(x: tailWidth * 0.75, y: 1.5),
                control2: CGPoint(x: tailWidth, y: 5))
        } else {
            path.addArc(
                tangent1End: CGPoint(x: tailWidth, y: 0), tangent2End: CGPoint(x: tailWidth, y: height), radius: radius)
        }
        path.addArc(
            tangent1End: CGPoint(x: tailWidth, y: height), tangent2End: CGPoint(x: width, y: height), radius: radius)
        path.closeSubpath()
        guard mirrored else { return path }
        var flip = CGAffineTransform(translationX: width, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &flip) ?? path
    }
}

/// The avatar never takes clicks itself: the row offers the sender's menu (`personMenu`).
final class AvatarHostView: NSHostingView<Avatar> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A quote's tinted block with its leading bar.
final class QuoteView: NSView {
    var bar = NSColor.systemBlue { didSet { needsDisplay = true } }
    var fill = NSColor.clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        fill.setFill()
        shape.fill()
        shape.addClip()
        bar.setFill()
        NSRect(x: 0, y: 0, width: RowLayout.quoteBar, height: bounds.height).fill()
    }
    /// Set when the quoted message is known: a click goes to it.
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { onClick == nil ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}

/// Text drawn into its bounds with `RowLayout.drawing`, the options it was measured with. With a background it is a
/// pill (text inset by `inset`); with `onClick` it is a button.
final class TextLabel: NSView {
    var text = NSAttributedString() {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(text.string)
        }
    }
    var background: NSColor? { didSet { needsDisplay = true } }
    var inset = NSSize.zero
    var onClick: (() -> Void)? {
        didSet {
            setAccessibilityElement(onClick != nil)
            setAccessibilityRole(onClick == nil ? .staticText : .button)
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Called when the pointer enters the label.
    var onHover: (() -> Void)? {
        didSet {
            guard oldValue == nil, onHover != nil else { return }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }
    var onExit: (() -> Void)?  // when the pointer leaves a label with `onHover`
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { onExit?() }  // not passed on: the row tracks its own hover
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let background {
            background.setFill()
            let radius = min(bounds.height / 2, 11)  // a capsule on one line; a wrapped service line keeps soft corners
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        text.draw(with: bounds.insetBy(dx: inset.width, dy: inset.height), options: RowLayout.drawing)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { onClick == nil ? nil : super.hitTest(point) }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}
