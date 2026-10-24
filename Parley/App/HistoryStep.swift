import AppKit

/// Back or Forward through the Go menu's history from a mouse or trackpad, as Safari and Finder take them: a mouse's
/// side buttons (3 back, 4 forward), or a swipe event, which mouse software such as Logitech's sends for those buttons
/// and a three-finger trackpad swipe sends when set to swipe between pages. Two-finger swipes arrive as scrolling and
/// stay with the timeline's swipe to reply.
enum HistoryStep {
    case back, forward

    init?(_ type: NSEvent.EventType, button: Int = -1, deltaX: CGFloat = 0) {
        switch type {
        case .otherMouseDown where button == 3, .swipe where deltaX > 0: self = .back
        case .otherMouseDown where button == 4, .swipe where deltaX < 0: self = .forward
        default: return nil
        }
    }

    init?(_ event: NSEvent) {
        switch event.type {
        case .otherMouseDown: self.init(.otherMouseDown, button: event.buttonNumber)
        case .swipe: self.init(.swipe, deltaX: event.deltaX)
        default: return nil
        }
    }
}
