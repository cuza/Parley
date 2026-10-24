import Foundation
import Testing

@testable import Parley

/// A Focus filter sets Do Not Disturb or a status as its Focus turns on, and takes back only what it set as it turns off.
struct FocusFilterTests {
    private let meeting = FocusStatus(doNotDisturb: false, status: "In a meeting", emoji: "📅")
    private let deepWork = FocusStatus(doNotDisturb: true)
    private let off = FocusStatus()

    @Test func turningOnSetsWhatTheFilterAsks() {
        #expect(FocusStatus.changes(from: off, to: deepWork) == [.doNotDisturb])
        #expect(FocusStatus.changes(from: off, to: meeting) == [.status("In a meeting", emoji: "📅")])
    }
    @Test func turningOffTakesBackWhatItSet() {
        #expect(FocusStatus.changes(from: deepWork, to: off) == [.endDoNotDisturb])
        #expect(FocusStatus.changes(from: meeting, to: off) == [.clearStatus])
        #expect(FocusStatus.changes(from: off, to: off).isEmpty)  // a Focus whose filter sets nothing
    }
    @Test func switchingFocusChangesOnlyWhatDiffers() {
        let both = FocusStatus(doNotDisturb: true, status: "In a meeting", emoji: "📅")
        #expect(FocusStatus.changes(from: meeting, to: both) == [.doNotDisturb])
        #expect(FocusStatus.changes(from: both, to: deepWork) == [.clearStatus])
        #expect(FocusStatus.changes(from: deepWork, to: deepWork).isEmpty)
    }
    /// A status of only spaces is no status.
    @Test func aBlankStatusSetsNone() {
        #expect(FocusStatus(doNotDisturb: false, status: "  ", emoji: "📅") == off)
    }
    /// On, then off: Google Chat shows Do Not Disturb and the status while the Focus is on, and neither after.
    @MainActor @Test func applyingChangesGoogleChatAndRemembersIt() async throws {
        let defaults = try #require(UserDefaults(suiteName: "FocusFilterTests-\(UUID().uuidString)"))
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let both = FocusStatus(doNotDisturb: true, status: "Heads down", emoji: "🎧")
        try await both.apply(to: store, defaults: defaults)
        guard case .doNotDisturb = store.ownStatus.availability else {
            Issue.record("Do Not Disturb isn't on")
            return
        }
        #expect(store.ownStatus.custom?.text == "Heads down")
        #expect(FocusStatus.applied(in: defaults) == both)
        try await off.apply(to: store, defaults: defaults)
        #expect(store.ownStatus.availability == .automatic)
        #expect(store.ownStatus.custom == nil)
        #expect(FocusStatus.applied(in: defaults) == off)
    }
}
