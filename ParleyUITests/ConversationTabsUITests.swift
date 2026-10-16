import XCTest

/// Two conversations opened in new windows share one window as tabs; the main window stays apart.
@MainActor final class ConversationTabsUITests: XCTestCase {
    func testConversationWindowsOpenAsTabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        // Windows restored from an earlier run would cover the sidebar: keep only the main one.
        for _ in 0..<10 {
            guard let extra = app.windows.allElementsBoundByIndex.first(where: { $0.identifier != "main" }) else { break }
            extra.buttons["_XCUI:CloseWindow"].click()
        }
        let settingsWindow = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        for name in ["Maria Chen", "Alex Rivera"] {
            // Bring the main window forward: the conversation window opened before may cover the sidebar.
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Parley"].firstMatch.click()
            let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
            sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.click()
            let menu = app.menuBars.menuBarItems["Conversation"]
            menu.click()
            menu.menuItems["Open in New Window"].click()
            sleep(1)
        }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "tabs"; shot.lifetime = .keepAlways; add(shot)
        // Two conversation tabs named after their conversations, in one window beside the main window.
        for name in ["Maria Chen", "Alex Rivera"] {
            XCTAssertTrue(app.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "title == %@ OR label == %@", name, name)).firstMatch.exists, "a tab named \(name)")
        }
        XCTAssertEqual(app.windows.count, 2, "the main window and the tabbed conversation window")
        // A tab moved out to its own window merges back with Window ▸ Merge All Windows; the main window stays apart.
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Move Tab to New Window"].click()
        XCTAssertTrue(app.windows.element(boundBy: 2).waitForExistence(timeout: 5), "the tab became its own window")
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Merge All Windows"].click()
        sleep(1)
        XCTAssertEqual(app.windows.count, 2, "merged back into one tabbed window, beside the main window")
        // Settings ▸ Appearance has the switch, on by default.
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Appearance"].firstMatch.click()
        let title = NSPredicate(format: "value == %@ OR label == %@", "Open conversation windows as tabs", "Open conversation windows as tabs")
        let row = app.groups.containing(title).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let settings = app.windows.containing(title).firstMatch
        let page = XCTAttachment(screenshot: settings.screenshot()); page.name = "settings"; page.lifetime = .keepAlways; add(page)
        settingsWindow.buttons["_XCUI:CloseWindow"].click()
    }
}
