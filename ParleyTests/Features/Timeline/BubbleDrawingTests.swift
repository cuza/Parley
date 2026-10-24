import AppKit
import Testing

@testable import Parley

@MainActor struct BubbleDrawingTests {
    @Test func aLaidOutBubbleHasItsShapeAndFill() throws {
        let bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        bubble.own = false
        bubble.tail = true
        bubble.layout()
        let layer = try #require(bubble.layer as? CAShapeLayer)
        #expect(layer.path != nil)
        #expect(layer.path?.boundingBox.width ?? 0 >= 190)
        #expect(layer.fillColor != nil && layer.fillColor != NSColor.black.cgColor)
        bubble.own = true
        #expect(layer.fillColor != nil && layer.fillColor != NSColor.black.cgColor)
    }
}
