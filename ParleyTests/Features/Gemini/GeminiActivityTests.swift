import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Ask Gemini at work: the status it sends while it works ("Collecting info"), and the steps behind its answer.
extension NetworkTests { @Suite struct GeminiActivityTests: NetworkSuite {} }

extension NetworkTests.GeminiActivityTests {
    private static func activity(_ state: Int32, _ text: String = "", topic: String = "q1")
        -> Dynamite_StreamEventsResponse
    {
        .with { response in
            response.event.groupID.dmID.dmID = "g"
            response.event.bodies = [
                .with { body in
                    body.eventType = .activityIndicatorChanged
                    body.activityIndicatorChanged = .with { indicator in
                        indicator.state = state
                        indicator.userID.id = "gemini"
                        indicator.context.topicID.topicID = topic
                        indicator.context.topicID.groupID.dmID.dmID = "g"
                        if !text.isEmpty { indicator.progress.text = text }
                    }
                }
            ]
        }
    }
    @Test func anAgentsStatusArrivesUntilItStops() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.activity(1))
        await backend.handle(Self.activity(1, "Collecting info"))
        await backend.handle(Self.activity(2))
        let events = await Self.drain(backend).filter { if case .activityChanged = $0 { true } else { false } }
        #expect(
            events == [
                .activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: "Thinking"),
                .activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: "Collecting info"),
                .activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: nil),
            ])
    }
}

@MainActor struct GeminiActivityStoreTests {
    @Test func theTypingBubbleShowsTheStatusInTheChatAndTheThread() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.apply(.activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: "Collecting info"))
        #expect(
            store.activity("dm/g", thread: nil)?.label == "Collecting info"
                && store.activity("dm/g", thread: nil)?.person == "gemini")
        #expect(store.activity("dm/g", thread: "dm/g/q1/q1")?.label == "Collecting info")
        store.apply(.activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: nil))
        #expect(store.activity("dm/g", thread: nil) == nil)
    }
}

struct GeminiThinkingTests {
    @Test func anAnswersStepsComeFromItsActivityAnnotation() throws {
        let proto = Dynamite_Message.with { built in
            built.id.messageID = "a1"
            built.id.parentID.topicID.topicID = "q1"
            built.creator.userID.id = "gemini"
            built.textBody = "Langfuse runs on Tadashi."
            built.annotations = [
                .with { annotation in
                    annotation.type = .activity
                    annotation.activityMetadata.log.entries = [
                        .with {
                            $0.title = "Searching Chat"
                            $0.content = "Looked for where it runs."
                        },
                        .with {
                            $0.title = "Checking Drive"
                            $0.content = "Found the infra notes."
                        },
                    ]
                }
            ]
        }
        let message = try #require(DynamiteMapper.message(proto, in: "dm/g", selfID: "me", people: [:]))
        #expect(
            message.thinking == [
                ThinkingStep(title: "Searching Chat", text: "Looked for where it runs."),
                ThinkingStep(title: "Checking Drive", text: "Found the infra notes."),
            ])
        #expect(message.text == "Langfuse runs on Tadashi.")
        let layout = RowLayout.make(TimelineRow.rows([message])[0], width: 600, own: false, kind: .direct)
        let line = try #require(layout.thinking)
        let text = try #require(layout.text)
        #expect(layout.bubble.contains(line) && line.maxY <= text.minY)
    }
}

/// Ask Gemini's composer asks Gemini, as Google Chat's does; in a thread it replies.
struct AskGeminiComposerTests {
    @Test func theComposerAsksGemini() {
        var gemini = Conversation.fixture("dm/g", kind: .direct, name: "Gemini")
        gemini.app = .gemini
        #expect(ChatView.composerPrompt(gemini) == "Ask Gemini…")
        #expect(ChatView.composerPrompt(gemini, thread: "dm/g/t/t") == "Reply")  // inside a session
        #expect(ChatView.composerPrompt(Conversation.fixture("dm/a", kind: .direct, name: "Alex")) == "Message")
    }
}
