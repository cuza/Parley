import AppIntentsTesting
import XCTest

/// Parley's actions and entities as Siri, Shortcuts and Spotlight reach them: out of process, through the system's App
/// Intents path, against the demo workspace. macOS 27's AppIntentsTesting runs them; nothing is spoken to Siri.
@available(macOS 27, *)
@MainActor final class AppIntentsUITests: XCTestCase {
    let app = XCUIApplication()
    var definitions: IntentDefinitions!
    override func setUp() async throws {
        app.launchArguments = ["-uiTestingDemo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        definitions = IntentDefinitions(bundleIdentifier: "dev.cuza.Parley.debug")
    }
    /// Siri resolves a spoken name to Parley's own people and conversations.
    func testSiriFindsPeopleAndConversations() async throws {
        let people = try await definitions.entities["SiriPerson"].entities(matching: "Alex")
        XCTAssertEqual(people.count, 1)
        let rooms = try await definitions.entities["SiriConversation"].entities(matching: "launch")
        XCTAssertEqual(try rooms.first?.displayName as String?, "Launch crew")
        let shortcuts = try await definitions.entities["ConversationEntity"].entities(matching: "design")
        XCTAssertEqual(try shortcuts.first?.name as String?, "Design studio")
    }
    /// Open Conversation opens it, as a Spotlight result or a shortcut does.
    func testOpenConversation() async throws {
        let launch = definitions.entities["ConversationEntity"].makeReference(identifier: "launch")
        _ = try await definitions.intents["OpenConversationIntent"].makeIntent(target: launch).run()
        // What Siri sees on screen afterwards: Launch crew's messages.
        try await Task.sleep(for: .seconds(1))
        let annotations = try await definitions.entities["SiriMessage"].viewAnnotations()
        let conversation: AnyAppEntity = try XCTUnwrap(annotations.first).entity.conversation
        XCTAssertEqual(try conversation.displayName as String, "Launch crew")
    }
    /// "Start a message to Alex": the DM opens with the words in its composer, unsent.
    func testSiriDraftFillsTheComposer() async throws {
        let alex = try await definitions.entities["SiriPerson"].entities(matching: "Alex Rivera")
        let person = try XCTUnwrap(alex.first)
        _ = try await definitions.intents["SiriDraftMessageIntent"].makeIntent(destination: person, content: "Lunch at 1?").run()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Lunch at 1?")
    }
    /// "This message": the open conversation's messages are on screen for Siri.
    func testMessagesOnScreenAreAnnotated() async throws {
        let annotations = try await definitions.entities["SiriMessage"].viewAnnotations()
        XCTAssertFalse(annotations.isEmpty, "the timeline names its messages for Siri")
    }
    /// A space by name through Send Message, as Siri's template can't take a space; the test answers its confirmation.
    func testSendToASpace() async throws {
        let spaces = try await definitions.entities["ConversationEntity"].entities(matching: "Engineering")
        let engineering = try XCTUnwrap(spaces.first)
        _ = try await definitions.intents["SendMessageIntent"].makeIntent(text: "Deploy at 3", conversation: engineering).run()
        _ = try await definitions.intents["OpenConversationIntent"].makeIntent(target: engineering).run()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Deploy at 3", "Deploy at 3"))
        XCTAssertTrue(sent.firstMatch.waitForExistence(timeout: 5), "the message is in the space")
    }
    /// A space named to Siri is a recipient: the draft opens the space with the words in its composer.
    func testSiriDraftToASpace() async throws {
        let found = try await definitions.entities["SiriPerson"].entities(matching: "Engineering")
        let engineering = try XCTUnwrap(found.first)
        _ = try await definitions.intents["SiriDraftMessageIntent"].makeIntent(destination: engineering, content: "Deploy at 3").run()
        // The demo's Engineering has no messages to annotate; the open composer, Engineering's, holds the draft.
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["composer"].value as? String, "Deploy at 3")
    }
}
