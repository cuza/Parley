import XCTest

/// Ways to open a conversation in a new window: in the sidebar, a double-click (as in Messages) or ⌘-click (as Safari's
/// new tab); in Home, the context menu or ⌘O for the selected rows, since there a click opens in place and ⌘-click
/// selects several. Conversation windows join as tabs.
@MainActor final class OpenInWindowUITests: XCTestCase {
    private func tabs(_ app: XCUIApplication) -> Int {
        let bar = app.descendants(matching: .tabGroup).matching(NSPredicate(format: "label BEGINSWITH %@", "Tab bar")).firstMatch
        guard bar.waitForExistence(timeout: 5), let label = bar.label.split(separator: ",").last else { return app.windows.count - 1 }
        return Int(label.filter(\.isNumber)) ?? 0
    }
    func testTheSidebarOpensWindowsWithADoubleClickOrCommandClick() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        func row(_ name: String) -> XCUIElement { sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch }
        row("Maria Chen").doubleClick()
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 5), "a double-click opens a window")
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Parley"].firstMatch.click()   // back to the main window
        XCUIElement.perform(withKeyModifiers: .command) { row("Launch crew").click() }
        sleep(1)
        XCTAssertEqual(app.windows.count, 2, "the main window and one tabbed conversation window")
        XCTAssertEqual(tabs(app), 2, "⌘-click adds a tab")
    }
    func testHomeOpensTheSelectedRowsInWindows() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo", "-uiTestingHome"]
        app.launch()
        let list = app.descendants(matching: .any)["shortcut-home"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        func middle(_ i: Int) -> XCUICoordinate { list.outlineRows.element(boundBy: i).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }
        XCUIElement.perform(withKeyModifiers: .command) { middle(0).click(); middle(2).click() }
        middle(2).rightClick()
        app.menuItems["Open in New Window"].firstMatch.click()
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(tabs(app), 2, "both selected conversations open, as tabs")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "home-windows"; shot.lifetime = .keepAlways; add(shot)

        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Parley"].firstMatch.click()
        XCUIElement.perform(withKeyModifiers: .command) { middle(4).click() }
        app.typeKey("o", modifierFlags: .command)
        sleep(1)
        XCTAssertEqual(tabs(app), 3, "⌘O opens the selected row too")
    }
}
