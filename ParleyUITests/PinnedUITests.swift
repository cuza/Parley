import XCTest

/// Pinned messages in the demo workspace: Design studio's info panel lists its board, and a message's menu offers to pin it.
@MainActor final class PinnedUITests: XCTestCase {
    func testTheBoardShowsInTheInfoPanel() throws {
        let app = launchDemo()
        let any = app.descendants(matching: .any)
        let replies = any.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND elementType != %d", "2 replies",
                XCUIElement.ElementType.scrollView.rawValue)
        ).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: 5))
        shot(app.windows.firstMatch, "timeline")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Design studio")).firstMatch.click()
        XCTAssertTrue(
            any.matching(NSPredicate(format: "label == %@ OR value == %@", "Board", "Board")).firstMatch
                .waitForExistence(timeout: 5))
        shot(app.windows.firstMatch, "info")
    }
}
