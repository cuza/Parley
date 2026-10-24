import XCTest

/// Someone typing shows as a thought bubble at the end of the conversation, with their picture and name; Ask Gemini at
/// work shows its status in one. VoiceOver reads who is typing.
@MainActor final class TypingBubbleUITests: XCTestCase {
    private func launch(dark: Bool = false) -> XCUIApplication {
        launchDemo(["-uiTestingTyping"] + (dark ? ["-uiTestingDark"] : []))
    }
    func testSomeoneTypingAndGeminiAtWork() throws {
        let app = launch()
        let typing = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Maria is typing…"))
            .firstMatch
        XCTAssertTrue(typing.waitForExistence(timeout: 8), "Maria's bubble, read as who is typing")
        shot(app.windows.firstMatch, "typing")
        app.descendants(matching: .any)["sidebar"].firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Ask Gemini")).firstMatch.click()
        let working = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Ask Gemini · Collecting info…")
        ).firstMatch
        XCTAssertTrue(working.waitForExistence(timeout: 8), "Gemini's bubble says what it's doing")
        shot(app.windows.firstMatch, "gemini")
    }
    /// Two typists share one bubble, their pictures stacked, named together.
    func testSeveralPeopleTyping() throws {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["sidebar"].firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Launch crew")).firstMatch.click()
        let both = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Alex and Maria are typing…")
        ).firstMatch
        XCTAssertTrue(both.waitForExistence(timeout: 8), "one bubble for both, read as both typing")
        shot(app.windows.firstMatch, "typing-several")
    }
    func testDark() throws {
        let app = launch(dark: true)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Maria is typing…")).firstMatch
                .waitForExistence(timeout: 8))
        shot(app.windows.firstMatch, "typing-dark")
    }
}
