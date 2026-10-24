import XCTest

/// The window's keyboard shortcuts are menu items, so the menus and Help's search list them.
@MainActor final class MenuShortcutsUITests: XCTestCase {
    func testShortcutsAreInTheMenus() throws {
        let app = launchDemo()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        for title in [
            "Search Messages…", "Edit Last Message", "Conversation Info", "Jump to Conversation…", "Next Unread",
            "Previous Unread",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "\(title) is in the menus")
        }
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Search Messages…"].click()
        XCTAssertTrue(app.buttons["Said in: Design studio"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(
            app.textFields["Jump to a conversation, person or space"].waitForExistence(timeout: 5),
            "⌘K still opens the switcher")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Edit message"].waitForExistence(timeout: 5), "⌘E edits my last message")
        app.typeKey(.escape, modifierFlags: [])
        let members = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", "3 members", "3 members")
        ).firstMatch
        XCTAssertFalse(members.exists)  // the info panel's section; the header's subtitle isn't a text element
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(members.waitForExistence(timeout: 5), "⇧⌘I shows the info panel")
    }
}

/// The Conversation and Format menus, as Mail has: a conversation's actions for the one on screen, and the composer's
/// formatting, on only while it is being typed in.
@MainActor final class ConversationAndFormatMenusUITests: XCTestCase {
    func testTheMenusActOnWhatIsOpen() throws {
        let app = launchDemo()
        let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Alex Rivera"))
            .firstMatch.click()  // opening it reads it

        app.menuBars.menuBarItems["Conversation"].click()
        for title in [
            "Mark as Unread", "Pin", "Mute", "Show Threads", "Open in New Window", "Copy Link", "Hide", "Block…",
        ] {
            XCTAssertTrue(app.menuItems[title].isEnabled, "Conversation ▸ \(title)")
        }
        shot(app, "conversation-menu")
        app.menuItems["Pin"].click()
        app.menuBars.menuBarItems["Conversation"].click()
        XCTAssertTrue(app.menuItems["Unpin"].waitForExistence(timeout: 5), "Pin pinned it")
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["Format"].click()
        XCTAssertFalse(app.menuItems["Bold"].isEnabled, "off with no composer being typed in")
        app.typeKey(.escape, modifierFlags: [])
        app.textViews["composer"].firstMatch.click()
        app.menuBars.menuBarItems["Format"].click()
        XCTAssertTrue(app.menuItems["Bold"].isEnabled, "on while typing")
        shot(app, "format-menu")
        app.typeKey(.escape, modifierFlags: [])
    }
}
