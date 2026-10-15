import XCTest

/// Ask Gemini as web Chat shows it, in the demo workspace: a greeting and the recent sessions; a session opens as its
/// thread, and closing it comes back.
@MainActor final class AskGeminiUITests: XCTestCase {
    func testSessionsOpenAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Ask Gemini")).firstMatch.click()
        let greeting = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Good ", "Good ")).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "the home greets")
        let session = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                                                "What's on my calendar tomorrow?", "What's on my calendar tomorrow?")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5), "the recent sessions are listed")
        let home = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); home.name = "home"; home.lifetime = .keepAlways; add(home)
        session.click()
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "Design review at 10")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "the session opens with Gemini's answer")
        let question = app.textViews.matching(NSPredicate(format: "value == %@", "What's on my calendar tomorrow?")).firstMatch   // a bubble, not the title
        XCTAssertTrue(question.exists, "the question is the session's first message, as on the web")
        let opened = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); opened.name = "session"; opened.lifetime = .keepAlways; add(opened)
        app.buttons["Close"].firstMatch.click()
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "closing the session comes back home")

        session.click()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])   // nothing clicked: no view in the session has focus
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "Esc comes back home right after opening a session")

        session.click()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.click()   // focus in the conversation, not the composer
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "Esc comes back home with focus in the conversation")

        session.click()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "Back (⌘[) comes back to Ask Gemini's home, not the previous conversation")
    }
}
