import XCTest

/// Scheduled send in the demo workspace: Drafts lists the waiting message, Launch crew's composer says when it goes out,
/// and right-clicking Send offers the times.
@MainActor final class ScheduledSendUITests: XCTestCase {
    func testScheduledMessagesShowAndSendOffersTimes() throws {
        let app = launchDemo()
        let any = app.descendants(matching: .any)
        let drafts = any.matching(NSPredicate(format: "value == %@", "Drafts")).firstMatch
        XCTAssertTrue(drafts.waitForExistence(timeout: 5))
        drafts.click()
        let row = any.matching(NSPredicate(format: "label CONTAINS %@", "the beta build goes out at noon")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        shot(app.windows.firstMatch, "drafts")
        row.hover()
        sleep(1)  // the buttons fading in: the row has them as accessibility actions, not elements to wait for
        shot(app.windows.firstMatch, "drafts-hover")  // the actions replace the time; VoiceOver has them as the row's actions

        any["sidebar"].firstMatch.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Launch crew")
        ).firstMatch.click()
        XCTAssertTrue(
            any.matching(NSPredicate(format: "label BEGINSWITH %@", "Scheduled for tomorrow")).firstMatch
                .waitForExistence(timeout: 5))
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))  // the demo draft is in the composer
        send.rightClick()
        XCTAssertTrue(app.menuItems["Choose Date and Time…"].waitForExistence(timeout: 5))
        shot(app.windows.firstMatch, "menu")
        app.typeKey(.escape, modifierFlags: [])
    }
}
