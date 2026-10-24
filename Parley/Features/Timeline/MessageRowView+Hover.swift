import AppKit

extension MessageRowView {
    /// Outside the bubble, level with the last pill, on the side away from the sender's tail.
    func addReactionFrame(_ layout: RowLayout) -> CGRect? {
        guard let last = layout.reactions.last else { return nil }
        let width = last.height + 10
        addReactionButton.layer?.cornerRadius = last.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            addReactionButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
        return CGRect(
            x: own ? layout.bubble.minX - 6 - width : layout.bubble.maxX + RowLayout.tailWidth + 6, y: last.minY,
            width: width, height: last.height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }
}
