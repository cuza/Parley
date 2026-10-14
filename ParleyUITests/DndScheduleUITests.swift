import XCTest

/// Settings ▸ Notifications lists the demo's do not disturb schedule, and Edit opens its editor.
@MainActor final class DndScheduleUITests: XCTestCase {
    private func shot(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testTheScheduleShowsInSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Notifications"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        XCTAssertTrue(app.buttons["Add Schedule…"].waitForExistence(timeout: 5))
        let settings = app.windows.containing(.button, identifier: "Add Schedule…").firstMatch
        shot(settings, "settings")
        app.buttons["Edit…"].firstMatch.click()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        shot(app.sheets.firstMatch.exists ? app.sheets.firstMatch : settings, "editor")
        app.buttons["Cancel"].firstMatch.click()
    }
}
