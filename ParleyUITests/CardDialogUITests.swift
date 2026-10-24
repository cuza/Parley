import XCTest

/// An app's dialog in the demo workspace: Shipyard's "Create issue", whose assignee sits in a collapsible section.
@MainActor final class CardDialogUITests: XCTestCase {
    /// The toggle is a disclosure button, as Google Chat draws it with a chevron: VoiceOver reads its words and its state,
    /// and a click shows what it hides.
    func testACollapsibleSectionOpensFromItsDisclosureButton() throws {
        let app = launchDemo()
        let create = app.buttons["Create issue"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.click()
        let toggle = app.buttons["More fields"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "collapsed")
        let assignee = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR placeholderValue == %@", "Assignee", "Who takes it?")
        ).firstMatch
        XCTAssertFalse(assignee.exists)
        toggle.click()
        XCTAssertTrue(assignee.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "expanded")
        shot(app.windows.firstMatch, "dialog expanded")
    }
}
