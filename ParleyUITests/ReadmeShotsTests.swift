import AppKit
import XCTest

/// Regenerates the README screenshots from the demo workspace: run it alone, then copy the PNGs it writes to the
/// test runner's temporary directory into Screenshots/. Each is the window as ⇧⌘4 then Space captures it: rounded
/// corners and the system shadow on a transparent margin. screencapture needs Screen Recording permission for
/// ParleyUITests-Runner (System Settings ▸ Privacy & Security); without it, it fails with "could not create image from window".
@MainActor final class ReadmeShotsTests: XCTestCase {
    private func shoot(_ name: String, dark: Bool = false, open: String? = nil) throws {
        let app = XCUIApplication()
        // The look is pinned here, not taken from this Mac's settings: no wallpaper, accent bubbles.
        app.launchArguments =
            [
                "-uiTestingDemo", "-wallpaper", "none", "-wallpaperDark", "none", "-wallpaperDoodles", "NO",
                "-bubbleColor", "", "-bubbleColorDark", "",
            ] + (dark ? ["-uiTestingDark"] : [])
        app.launch()
        let replies = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND elementType != %d", "2 replies",
                XCUIElement.ElementType.scrollView.rawValue)
        ).firstMatch  // the link, not the timeline around it
        XCTAssertTrue(replies.waitForExistence(timeout: 5))
        if open == "thread" { replies.click() }
        if open == "home" {
            app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Home")).firstMatch.click()
        }
        // The app DM's row has an unread badge, so it reads as one element labelled "Notebook, 1 unread".
        if open == "apps" {
            app.descendants(matching: .any)["sidebar"].firstMatch.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Notebook")
            ).firstMatch.click()
        }
        if open == "info" {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Design studio")).firstMatch.click()
        }
        // Park the pointer on empty sidebar space so no hover tooltip is captured.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).hover()
        sleep(3)  // no element to wait for: the window's last redraw and the hover's tooltip fading
        let file = URL(filePath: NSTemporaryDirectory()).appending(path: "\(name).png")
        let capture = Process()
        capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l\(try windowID())", file.path]  // -x: no shutter sound
        let errors = Pipe()
        capture.standardError = errors
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(
            capture.terminationStatus, 0,
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        app.terminate()
    }
    /// The launched app's window: the newest Parley not running from /Applications, its largest normal-level window.
    private func windowID() throws -> CGWindowID {
        let pid = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.cuza.Parley.debug")
                .filter { $0.bundleURL?.path.hasPrefix("/Applications/") == false }
                .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?.processIdentifier)
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        let mine = windows.filter { $0[kCGWindowOwnerPID] as? pid_t == pid && $0[kCGWindowLayer] as? Int == 0 }
        func area(_ window: [CFString: Any]) -> CGFloat {
            let bounds = window[kCGWindowBounds] as? [String: CGFloat] ?? [:]
            return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
        }
        return try XCTUnwrap(mine.max { area($0) < area($1) }?[kCGWindowNumber] as? CGWindowID)
    }
    /// Runs only when asked (`TEST_RUNNER_PARLEY_README_SHOTS=1 xcodebuild test …`): it needs Screen Recording, which a
    /// normal UI test run doesn't have.
    func testReadmeScreenshots() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PARLEY_README_SHOTS"] != nil,
            "set PARLEY_README_SHOTS to regenerate them")
        try shoot("home", open: "home")
        try shoot("conversation")
        try shoot("thread-dark", dark: true, open: "thread")
        try shoot("info", open: "info")
        try shoot("apps", open: "apps")
    }
}
