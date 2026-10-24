import Foundation
import Testing

@testable import Parley

/// Status actions change Google Chat's status as the status menu does, and throw what went wrong instead of showing it.
@MainActor struct StatusIntentTests {
    @Test func aChangeRunsAndAFailureIsThrown() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        try await store.changeStatus { await $0.setAway(true) }
        #expect(store.ownStatus.availability == .away)
        await fake.simulateChangeFailure()
        await #expect(throws: ParleyIntentError.self) { try await store.changeStatus { await $0.setAway(false) } }
        #expect(store.error == nil)  // thrown to the action, not left for a window
    }
    @Test func durationsAreTheStatusMenus() {
        #expect(DoNotDisturbDuration.allCases.map(\.seconds) == [1800, 3600, 7200, 14_400, 28_800, 86_400])
    }
}
