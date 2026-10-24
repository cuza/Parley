import Foundation
import Testing

@testable import Parley

/// A change shown before Google confirms it: on screen first, put back on a refusal, which a note or an alert explains.
@MainActor struct OptimisticChangeTests {
    struct Refused: LocalizedError { var errorDescription: String? { "Not allowed." } }

    @Test func itShowsBeforeTheCallAndStaysWhenGoogleAgrees() async {
        let (store, _) = await started()
        var shown = false
        var shownDuringCall = false
        var undone = false
        await store.optimistically(.toast("pin it")) {
            shown = true
        } undo: {
            undone = true
        } send: {
            shownDuringCall = shown
        }
        #expect(shownDuringCall && shown && !undone)
        #expect(store.toast == nil && store.error == nil)
    }
    @Test func aRefusalThatCanBeRetriedIsPutBackWithANote() async {
        let (store, _) = await started()
        var shown = false
        await store.optimistically(.toast("pin it")) {
            shown = true
        } undo: {
            shown = false
        } send: {
            throw Refused()
        }
        #expect(!shown)
        #expect(store.toast == "Couldn't pin it. Not allowed." && store.error == nil)
    }
    @Test func aRefusalTheUserMustActOnIsPutBackWithAnAlert() async {
        let (store, _) = await started()
        var shown = false
        await store.optimistically(.alert) {
            shown = true
        } undo: {
            shown = false
        } send: {
            throw Refused()
        }
        #expect(!shown)
        #expect(store.error == "Not allowed." && store.toast == nil)
    }
    @Test func aCancelledCallIsPutBackQuietly() async {
        let (store, _) = await started()
        var shown = false
        await store.optimistically(.alert) {
            shown = true
        } undo: {
            shown = false
        } send: {
            throw CancellationError()
        }
        #expect(!shown && store.error == nil && store.toast == nil)
    }
    /// Taking a role away that Google kept leaves the person its access, so that one is an alert; giving one is a note.
    @Test func aRefusedRoleChangeAlertsOnlyWhenItTookAccessAway() async {
        let (store, fake) = await started()
        store.rooms.roles["general", default: [:]]["alex"] = .manager
        await fake.simulateChangeFailure()
        await store.setRole(.member, for: "alex", in: "general")
        #expect(store.rooms.roles["general"]?["alex"] == .manager && store.error != nil && store.toast == nil)
        store.error = nil
        await fake.simulateChangeFailure()
        await store.setRole(.owner, for: "alex", in: "general")
        #expect(store.rooms.roles["general"]?["alex"] == .manager && store.toast != nil && store.error == nil)
    }
}
