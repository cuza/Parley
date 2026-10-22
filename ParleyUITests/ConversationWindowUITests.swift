import XCTest

/// A conversation's own window: room for the threads list beside the timeline, and the tab bar's + offering the palette.
@MainActor final class ConversationWindowUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The demo with Maria Chen open in her own window, the other windows closed.
    private func openMariasWindow() -> XCUIElement {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            guard let extra = app.windows.allElementsBoundByIndex.first(where: { $0.identifier != "main" }) else { break }
            extra.buttons["_XCUI:CloseWindow"].click()
        }
        let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
        sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Maria Chen")).firstMatch.click()
        let menu = app.menuBars.menuBarItems["Conversation"]
        menu.click()
        menu.menuItems["Open in New Window"].click()
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "main")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Maria Chen's own window")
        return window
    }

    /// The threads list is a side pane like Info: showing it widens the window to fit it beside the timeline (380 + 1 +
    /// 340 points), instead of cutting both off.
    func testShowingThreadsMakesRoomForThem() throws {
        let window = openMariasWindow()
        let menu = app.menuBars.menuBarItems["Conversation"]
        menu.click()
        menu.menuItems["Show Threads"].click()
        let wide = expectation(for: NSPredicate { _, _ in window.frame.width >= 720 }, evaluatedWith: nil)
        wait(for: [wide], timeout: 5)   // the window animates to its new width
    }

    /// File ▸ New Tab (⌘T), as the tab bar's + does, opens a tab with the conversation palette, ready for typing; the
    /// pick becomes that tab.
    func testNewTabOffersThePalette() throws {
        _ = openMariasWindow()
        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Jump to a conversation, person or space")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette in the new tab")
        app.typeText("gene")
        app.typeKey(.return, modifierFlags: [])
        let tab = app.tabGroups["tab bar"].descendants(matching: .any).matching(NSPredicate(format: "title == %@", "General")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the new tab became General")
        XCTAssertFalse(field.exists, "the palette gave way to the conversation")
    }
}
