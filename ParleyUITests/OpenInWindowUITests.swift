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
    /// A conversation window has its own thread and info panes: opening one there leaves the main window as it was,
    /// even when both show the same conversation.
    func testAConversationWindowOpensPanesOfItsOwn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        let main = app.windows["main"]
        XCTAssertTrue(main.textViews["composer"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Conversation"].click()
        app.menuItems["Open in New Window"].firstMatch.click()
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "main")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "a conversation window")
        let replies = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND elementType != %d", "2 replies", XCUIElement.ElementType.scrollView.rawValue)).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: 10), "the window's timeline loads")   // a new window loads its page first
        replies.click()
        XCTAssertTrue(window.staticTexts["Thread"].waitForExistence(timeout: 5), "the thread opens in the window")
        XCTAssertFalse(main.staticTexts["Thread"].exists, "and not in the main window")

        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(window.staticTexts["Info"].waitForExistence(timeout: 5), "Info opens in the window")
        XCTAssertFalse(main.staticTexts["Info"].exists, "and not in the main window")
    }
}
