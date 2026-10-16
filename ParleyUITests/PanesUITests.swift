import XCTest

/// The panes read alike: the info panel has a header with a close button, as the thread pane has, and Home has the
/// search button conversations have.
@MainActor final class PanesUITests: XCTestCase {
    func testTheInfoPanelClosesFromItsHeader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .shift])
        let header = app.staticTexts["Info"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the panel names itself, as the thread pane does")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "info"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Close"].firstMatch.click()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "its close button closes it")
    }
    func testHomeHasTheSearchButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo", "-uiTestingHome"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["shortcut-home"].firstMatch.waitForExistence(timeout: 5))
        let search = app.toolbars.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Home has the search button")
        search.click()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "it opens search")
    }
    /// The conversation's toolbar is customizable, as Mail's: View ▸ Customize Toolbar… offers Info and Attach.
    func testTheToolbarIsCustomizable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["View"].click()
        let customize = app.menuItems["Customize Toolbar…"]
        XCTAssertTrue(customize.waitForExistence(timeout: 3) && customize.isEnabled, "View ▸ Customize Toolbar…")
        customize.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        for item in ["Info", "Attach", "Search", "Threads", "Video Call"] {
            XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", item, item, item)).firstMatch.exists,
                          "\(item) is offered")
        }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "customize"; shot.lifetime = .keepAlways; add(shot)
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
}
