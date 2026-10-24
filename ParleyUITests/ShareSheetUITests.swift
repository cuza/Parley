import AppKit
import XCTest

/// The share sheet's Parley hands what's shared to the running app, which asks for the conversation and puts it into
/// that conversation's draft, unsent.
@MainActor final class ShareSheetUITests: XCTestCase {
    func testSharedTextLandsInTheDraft() throws {
        let app = launchDemo()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let text = "Lunch at 1 on Thursday?"
        let services = NSSharingService.sharingServices(forItems: [text])
        // Debug builds are "Parley Debug", so the installed Parley's own extension is never the one under test.
        let parley = try XCTUnwrap(
            services.first { $0.title == "Parley Debug" }, "share services: \(services.map(\.title))")
        parley.perform(withItems: [text])
        let picker = app.textFields["Send to a conversation or person"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Parley asks for the conversation")
        picker.typeText("Alex")
        app.typeKey(.return, modifierFlags: [])
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, text)
    }
    /// The hand-off alone: a pasteboard by name and the parley-debug://share link that names it.
    func testAShareLinkOpensThePicker() throws {
        let app = launchDemo()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let name = "dev.cuza.Parley.share.uitest-\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: .init(name))
        pasteboard.clearContents()
        pasteboard.setString("From the share link", forType: .string)
        NSWorkspace.shared.open(URL(string: "parley-debug://share?pasteboard=\(name)")!)
        XCTAssertTrue(
            app.textFields["Send to a conversation or person"].waitForExistence(timeout: 10),
            "Parley asks for the conversation")
    }
}
