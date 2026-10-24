import XCTest

/// Opening a thread puts the keyboard in its composer, so the reply can be typed right away; Esc closes the thread pane
/// and gives the keyboard back to the conversation's composer.
@MainActor final class ThreadFocusUITests: XCTestCase {
    func testTheThreadComposerTakesTheKeyboardAndEscClosesIt() throws {
        let app = launchDemo()
        let replies = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND elementType != %d", "2 replies",
                    XCUIElement.ElementType.scrollView.rawValue)
            ).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: 5))
        replies.click()
        XCTAssertTrue(app.staticTexts["Thread"].waitForExistence(timeout: 5))
        // The composer takes the keyboard just after the pane appears: wait for it, or a busy run types too soon.
        let focused = app.textViews.matching(
            NSPredicate(format: "identifier == %@ AND hasKeyboardFocus == true", "composer")
        ).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5), "a composer has the keyboard")
        app.typeText("hi")
        let typed = app.textViews.matching(NSPredicate(format: "identifier == %@ AND value == %@", "composer", "hi"))
            .firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: 3), "the thread's composer had the keyboard")

        app.typeKey(.escape, modifierFlags: [])
        // The first Esc may only dismiss macOS's inline prediction for "hi", as in any text field.
        if !app.staticTexts["Thread"].waitForNonExistence(timeout: 1) { app.typeKey(.escape, modifierFlags: []) }
        XCTAssertTrue(app.staticTexts["Thread"].waitForNonExistence(timeout: 5), "Esc closes the thread")
        app.typeText("x")
        let main = app.textViews["composer"].firstMatch
        XCTAssertTrue(
            (main.value as? String)?.hasSuffix("x") == true, "the conversation's composer has the keyboard again")
    }
    /// With the thread pane's composer in use, Conversation ▸ Open Thread in New Window (⌘O) pops the thread out.
    func testCommandOOpensTheFocusedThreadInAWindow() throws {
        let app = launchDemo()
        let replies = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND elementType != %d", "2 replies",
                    XCUIElement.ElementType.scrollView.rawValue)
            ).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: 5))
        replies.click()
        XCTAssertTrue(app.staticTexts["Thread"].waitForExistence(timeout: 5))
        let focused = app.textViews.matching(
            NSPredicate(format: "identifier == %@ AND hasKeyboardFocus == true", "composer")
        ).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5), "the thread's composer has the keyboard")  // what ⌘O follows
        app.menuBars.menuBarItems["Conversation"].click()
        XCTAssertTrue(
            app.menuItems["Open Thread in New Window"].waitForExistence(timeout: 3), "the item names what it opens")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 5), "a thread window")
        XCTAssertFalse(app.windows["main"].staticTexts["Thread"].exists, "the pane closed")
    }
}
