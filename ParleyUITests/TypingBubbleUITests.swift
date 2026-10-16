import XCTest

/// Someone typing shows as a thought bubble at the end of the conversation, with their picture and name; Ask Gemini at
/// work shows its status in one. VoiceOver reads who is typing.
@MainActor final class TypingBubbleUITests: XCTestCase {
    private func launch(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo", "-uiTestingTyping"] + (dark ? ["-uiTestingDark"] : [])
        app.launch()
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testSomeoneTypingAndGeminiAtWork() throws {
        let app = launch()
        let typing = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Maria is typing…")).firstMatch
        XCTAssertTrue(typing.waitForExistence(timeout: 8), "Maria's bubble, read as who is typing")
        shot(app, "typing")
        app.descendants(matching: .any)["sidebar"].firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Ask Gemini")).firstMatch.click()
        let working = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Ask Gemini · Collecting info…")).firstMatch
        XCTAssertTrue(working.waitForExistence(timeout: 8), "Gemini's bubble says what it's doing")
        shot(app, "gemini")
    }
    /// Two typists share one bubble, their pictures stacked, named together.
    func testSeveralPeopleTyping() throws {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["sidebar"].firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Launch crew")).firstMatch.click()
        let both = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Alex and Maria are typing…")).firstMatch
        XCTAssertTrue(both.waitForExistence(timeout: 8), "one bubble for both, read as both typing")
        shot(app, "typing-several")
    }
    func testDark() throws {
        let app = launch(dark: true)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Maria is typing…")).firstMatch.waitForExistence(timeout: 8))
        shot(app, "typing-dark")
    }
}
