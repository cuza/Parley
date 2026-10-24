import XCTest

@MainActor extension XCTestCase {
    /// Parley on the demo workspace, launched with `arguments` after `-uiTestingDemo`.
    func launchDemo(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingDemo"] + arguments
        app.launch()
        return app
    }
    /// Keeps a screenshot of `element` (a window, a menu, the whole app) in the test's results as `name`.
    func shot(_ element: XCUIElement, _ name: String, lifetime: XCTAttachment.Lifetime = .keepAlways) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = lifetime
        add(attachment)
    }
    /// Waits up to `timeout` seconds for `condition`, then fails with `what` if it still doesn't hold.
    func wait(_ what: String, timeout: TimeInterval = 10, until condition: @escaping () -> Bool) {
        let holds = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [holds], timeout: timeout), .completed, what)
    }
}
