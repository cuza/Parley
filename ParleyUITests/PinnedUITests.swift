import XCTest

/// Pinned messages in the demo workspace: Design studio's info panel lists its board, and a message's menu offers to pin it.
@MainActor final class PinnedUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testTheBoardShowsInTheInfoPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        let any = app.descendants(matching: .any)
        let replies = any.matching(NSPredicate(format: "label CONTAINS %@ AND elementType != %d", "2 replies", XCUIElement.ElementType.scrollView.rawValue)).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: 5))
        shot(app, "timeline")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Design studio")).firstMatch.click()
        XCTAssertTrue(any.matching(NSPredicate(format: "label == %@ OR value == %@", "Board", "Board")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "info")
    }
}
