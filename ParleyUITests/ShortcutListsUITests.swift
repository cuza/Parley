import XCTest

/// Home is a list you select in, as Mail's message list: a click opens a row, ⌘-click selects without opening, the
/// context menu acts on every selected row, and Return opens.
@MainActor final class ShortcutListsUITests: XCTestCase {
    func testHomeRowsSelectAndOpen() throws {
        let app = launchDemo()
        let home = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Home")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.click()
        let list = app.descendants(matching: .any)["shortcut-home"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let rows = list.descendants(matching: .tableRow).count > 0 ? list.tableRows : list.outlineRows
        XCTAssertGreaterThan(rows.count, 2)

        // SwiftUI's list rows report themselves not hittable: click their middle.
        func middle(_ index: Int) -> XCUICoordinate {
            rows.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        }
        XCUIElement.perform(withKeyModifiers: .command) {
            middle(0).click()
            middle(1).click()
        }
        XCTAssertTrue(list.exists, "⌘-click selects without opening")
        XCTAssertTrue(
            list.value(forKey: "hasKeyboardFocus") as? Bool == true, "choosing rows takes the keyboard from the sidebar"
        )
        middle(1).rightClick()
        shot(app, "home-menu")
        XCTAssertTrue(
            app.menuItems["Mark as Read"].exists || app.menuItems["Unfollow Thread"].exists
                || app.menuItems["Unfollow Threads"].exists)
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(list.waitForNonExistence(timeout: 5), "Return opens the selected row")

        home.click()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        middle(0).click()
        XCTAssertTrue(list.waitForNonExistence(timeout: 5), "a click opens the row")
    }
    /// Home gets the keyboard when nothing else has it: at launch, as Mail's message list has it, and back from a
    /// conversation, whose composer had it. ↓ then selects the first row and Return opens it, without a click. (A click in
    /// the sidebar keeps the keyboard there, as in Mail; Tab moves on.)
    func testArrowKeysWorkWhenHomeHasNothingElseToGiveTheKeyboardTo() throws {
        let app = launchDemo(["-uiTestingHome"])
        let list = app.descendants(matching: .any)["shortcut-home"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.outlineRows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()  // opens it
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))
        app.textViews["composer"].firstMatch.click()
        app.typeKey("[", modifierFlags: .command)  // Go ▸ Back to Home
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: list)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 3), .completed, "Home has the keyboard")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(list.waitForNonExistence(timeout: 5), "↓ then Return opens the first row")
    }
}

/// View ▸ Bigger, Smaller and Actual Size scale message text, as Mail's do.
@MainActor final class TextSizeUITests: XCTestCase {
    func testBiggerAndSmallerScaleMessages() throws {
        let app = launchDemo()
        let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Alex Rivera"))
            .firstMatch.click()
        let message = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "ready for a first look")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        app.typeKey("0", modifierFlags: .command)
        let usual = message.frame.height
        for _ in 0..<3 { app.typeKey("+", modifierFlags: .command) }
        XCTAssertGreaterThan(message.frame.height, usual + 4, "⌘+ makes the message bigger")
        shot(app.windows.firstMatch, "bigger")
        app.typeKey("0", modifierFlags: .command)
        XCTAssertEqual(message.frame.height, usual, accuracy: 1, "⌘0 is the usual size again")
        app.typeKey("-", modifierFlags: .command)
        XCTAssertLessThan(message.frame.height, usual, "⌘− makes it smaller")
        app.typeKey("0", modifierFlags: .command)

        // Settings ▸ Appearance has the same size as a slider.
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Appearance"].firstMatch.click()
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        let slider = settings.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 1)
        shot(settings, "settings")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertGreaterThan(message.frame.height, usual + 4, "the slider's largest size")
        app.typeKey("0", modifierFlags: .command)
    }
}
