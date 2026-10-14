import XCTest

/// The search panel's chips in the demo workspace: Has ▸ Image alone finds the demo's photo, shown as a thumbnail; a
/// Drive document shows by name.
@MainActor final class SearchFiltersUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testChipsSearchOnTheirOwn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        let has = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@", "Has", "Has")).firstMatch
        XCTAssertTrue(has.waitForExistence(timeout: 5))
        shot(app, "chips")
        // ⌘F starts said in the open conversation; Clear searches everywhere.
        XCTAssertTrue(app.buttons["Said in: Design studio"].exists)
        app.links["Clear"].click()
        // Said in picks conversations by name.
        app.buttons["Said in"].click()
        app.checkBoxes["Maria Chen"].click()
        XCTAssertTrue(app.buttons["Said in: Maria Chen"].waitForExistence(timeout: 5))
        shot(app, "said in")
        app.typeKey(.escape, modifierFlags: [])
        app.links["Clear"].click()
        has.click()
        app.menuItems["Image"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR title BEGINSWITH %@", "Has: Image", "Has: Image")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Launch crew")).firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        shot(app, "image")
        app.links["Clear"].click()
        app.typeText("launch plan")
        XCTAssertTrue(app.staticTexts["Launch plan"].waitForExistence(timeout: 5))
        shot(app, "document")
        // A click anywhere on a result opens it.
        let result = app.staticTexts["Launch plan for next week"]
        let row = result.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 300, dy: 0))
        row.click()
        XCTAssertTrue(app.buttons["Close"].waitForNonExistence(timeout: 5), "the panel closes on the message")
        // ⌘F is the same panel, said in the open conversation.
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Said in: Launch crew"].waitForExistence(timeout: 5))
        shot(app, "command f")
    }
}
