import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Failures read as plain sentences, and a change that is put back says so for a moment instead of stopping the user.
@MainActor struct ErrorWordingTests {
    @Test func commonFailuresReadPlainly() {
        #expect(
            ChatStore.plain(URLError(.notConnectedToInternet)) == "You're offline. Check your connection and try again."
        )
        #expect(
            ChatStore.plain(URLError(.timedOut)) == "Google Chat didn't answer. Check your connection and try again.")
        #expect(ChatStore.plain(AuthFailure.http(403)) == "Google Chat refused this (HTTP 403).")
        #expect(!ChatStore.plain(URLError(.networkConnectionLost)).contains("NSURLErrorDomain"))
    }
    @Test func aChangePutBackIsANoteNotAnAlert() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await fake.simulateChangeFailure()
        await store.setSidebarPinned(true, "general")
        #expect(store.error == nil)
        #expect(store.toast?.hasPrefix("Couldn't change the conversation.") == true)
        #expect(store.rooms.conversations.first { $0.id == "general" }?.pinned == false)
    }
}
