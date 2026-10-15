import XCTest

/// Deleting a message removes it for everyone, so Parley asks first, as Google Chat does: Cancel keeps it, Delete removes it.
@MainActor final class DeleteMessageUITests: XCTestCase {
    func testDeleteAsksFirst() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        let any = app.descendants(matching: .any)
        let maria = any.matching(NSPredicate(format: "value == %@ OR label BEGINSWITH %@", "Maria Chen", "Maria Chen,")).firstMatch
        XCTAssertTrue(maria.waitForExistence(timeout: 5))
        maria.click()
        let mine = app.textViews.matching(NSPredicate(format: "value == %@", "Absolutely. Send it over!")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))

        mine.rightClick()
        app.menuItems["Delete…"].click()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "Delete asks first")
        let cancel = dialog.buttons["Cancel"]
        let asked = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); asked.name = "asks"; asked.lifetime = .keepAlways; add(asked)
        cancel.click()
        XCTAssertTrue(mine.waitForExistence(timeout: 2), "Cancel keeps the message")

        mine.rightClick()
        app.menuItems["Delete…"].click()
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        dialog.buttons["Delete"].click()
        XCTAssertTrue(mine.waitForNonExistence(timeout: 5), "Delete removes it")
    }
}
