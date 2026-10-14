import XCTest

/// The window's keyboard shortcuts are menu items, so the menus and Help's search list them.
@MainActor final class MenuShortcutsUITests: XCTestCase {
    func testShortcutsAreInTheMenus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        for title in ["Search Messages…", "Edit Last Message", "Conversation Info", "Jump to Conversation…", "Next Unread", "Previous Unread"] {
            XCTAssertTrue(app.menuItems[title].exists, "\(title) is in the menus")
        }
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Search Messages…"].click()
        XCTAssertTrue(app.buttons["Said in: Design studio"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Jump to a conversation, person or space"].waitForExistence(timeout: 5), "⌘K still opens the switcher")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Edit message"].waitForExistence(timeout: 5), "⌘E edits my last message")
        app.typeKey(.escape, modifierFlags: [])
        let members = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "3 members", "3 members")).firstMatch
        XCTAssertFalse(members.exists)   // the info panel's section; the header's subtitle isn't a text element
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(members.waitForExistence(timeout: 5), "⌘I shows the info panel")
    }
}
