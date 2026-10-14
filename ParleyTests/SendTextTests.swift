import Foundation
import Testing
@testable import Parley

/// Shortcuts' and Siri's Send Message: plain text to a conversation, through the same path as the composer.
@MainActor struct SendTextTests {
    @Test func sendsAndSaysWhetherItWent() async {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        #expect(await store.sendText("  Running late, start without me  ", to: "alex"))
        #expect(store.messages.contains { $0.conversationID == "alex" && $0.text == "Running late, start without me" && $0.delivery == .sent })
        await fake.simulateSendFailure()
        #expect(await store.sendText("Second try", to: "alex") == false)
        #expect(await store.sendText("   ", to: "alex") == false)          // nothing to send
        #expect(await store.sendText("Hello", to: "space/unknown") == false)   // not one of mine
    }
    /// An action can run before Parley has its conversations, when it launched Parley: it waits for the first list.
    @Test func waitsForTheFirstList() async {
        let store = ChatStore(backend: FakeBackend())
        Task { try? await Task.sleep(for: .milliseconds(200)); await store.start() }
        await store.listed()
        #expect(!store.conversations.isEmpty)
    }
}
