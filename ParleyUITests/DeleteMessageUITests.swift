import XCTest

/// Deleting a message removes it for everyone, so Parley asks first, as Google Chat does: Cancel keeps it, Delete removes it.
@MainActor final class DeleteMessageUITests: XCTestCase {
    func testDeleteAsksFirst() throws {
        let app = launchDemo()
        let any = app.descendants(matching: .any)
        let sidebar = any["sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let maria = sidebar.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Maria Chen")
        ).firstMatch
        XCTAssertTrue(maria.waitForExistence(timeout: 5))
        maria.click()
        let mine = app.textViews.matching(NSPredicate(format: "value == %@", "Absolutely. Send it over!")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))

        mine.rightClick()
        app.menuItems["Delete…"].click()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "Delete asks first")
        let cancel = dialog.buttons["Cancel"]
        shot(app.windows.firstMatch, "asks")
        cancel.click()
        XCTAssertTrue(mine.waitForExistence(timeout: 2), "Cancel keeps the message")

        mine.rightClick()
        app.menuItems["Delete…"].click()
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        dialog.buttons["Delete"].click()
        XCTAssertTrue(mine.waitForNonExistence(timeout: 5), "Delete removes it")
    }
}
