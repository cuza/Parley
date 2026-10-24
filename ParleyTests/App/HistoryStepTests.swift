import AppKit
import Testing

@testable import Parley

/// A mouse's side buttons and a page swipe walk the Go menu's history, as in Safari and Finder.
struct HistoryStepTests {
    @Test func sideButtonsGoBackAndForward() {
        #expect(HistoryStep(.otherMouseDown, button: 3) == .back)
        #expect(HistoryStep(.otherMouseDown, button: 4) == .forward)
        #expect(HistoryStep(.otherMouseDown, button: 2) == nil)  // the wheel's click stays a click
    }

    /// Logitech's software and a three-finger trackpad swipe send swipe events, not buttons.
    @Test func swipesGoBackAndForward() {
        #expect(HistoryStep(.swipe, deltaX: 1) == .back)
        #expect(HistoryStep(.swipe, deltaX: -1) == .forward)
        #expect(HistoryStep(.swipe, deltaX: 0) == nil)  // a vertical swipe
    }

    @Test func aRealSideButtonEvent() throws {
        let back = try #require(CGMouseButton(rawValue: 3))
        let cgEvent = try #require(
            CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: back))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        #expect(HistoryStep(event) == .back)
    }
}
