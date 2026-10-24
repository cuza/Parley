import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Sidebar actions in the store: shown at once, sent to the server, put back when the server refuses.
@MainActor
struct SidebarStoreTests {
    private func room(_ store: ChatStore, _ id: ConversationID) -> Conversation? {
        store.rooms.conversations.first { $0.id == id }
    }

    @Test func pinShowsBeforeTheServerAnswers() async throws {
        let (store, fake) = await started(FakeBackend(latency: .milliseconds(400)))
        let pending = Task { await store.setSidebarPinned(true, "alex") }
        await eventually { room(store, "alex")?.pinned == true }
        #expect(room(store, "alex")?.pinned == true)
        await pending.value
        #expect(await fake.changes == ["pin alex"])
    }
    @Test func pinAndMuteSurviveARefresh() async throws {
        let (store, fake) = await started()
        await store.setSidebarPinned(true, "alex")
        await store.setMuted(true, "alex")
        await store.setSidebarPinned(false, "maria")
        try await store.refresh()
        #expect(
            room(store, "alex")?.pinned == true && room(store, "alex")?.muted == true
                && room(store, "maria")?.pinned == false)
        #expect(await fake.changes == ["pin alex", "mute alex", "unpin maria"])
        #expect(store.error == nil)
    }
    @Test func aRefusedPinOrMuteRollsBackAndSaysWhy() async throws {
        let (store, fake) = await started()
        await fake.simulateChangeFailure()
        await store.setSidebarPinned(true, "alex")
        #expect(room(store, "alex")?.pinned == false && store.toast != nil && store.error == nil)  // a note, not an alert
        store.toast = nil
        await fake.simulateChangeFailure()
        await store.setMuted(false, "engineering")
        #expect(room(store, "engineering")?.muted == true && store.toast != nil)
    }
    @Test func markUnreadShowsUnreadAndSurvivesARefresh() async throws {
        let (store, fake) = await started()
        #expect(room(store, "launch")?.unread == 0)
        await store.markUnread("launch")
        #expect(room(store, "launch")?.unread == 1)
        try await store.refresh()
        #expect(room(store, "launch")?.unread == 1)
        #expect(await fake.changes == ["unread launch"])
    }
    @Test func aRefusedMarkUnreadRollsBack() async throws {
        let (store, fake) = await started()
        await fake.simulateChangeFailure()
        await store.markUnread("launch")
        #expect(room(store, "launch")?.unread == 0 && store.toast != nil)
    }
    @Test func leaveRemovesTheConversationAndARefusalPutsItBack() async throws {
        let (store, fake) = await started()
        let index = try #require(store.rooms.conversations.firstIndex { $0.id == "general" })
        await fake.simulateChangeFailure()
        await store.leave("general")
        #expect(store.rooms.conversations.firstIndex { $0.id == "general" } == index && store.error != nil)
        store.error = nil
        await store.leave("general")
        #expect(room(store, "general") == nil && store.error == nil)
        try await store.refresh()
        #expect(room(store, "general") == nil)
    }
    @Test func leavingTheOpenConversationMovesTheSelection() async throws {
        let (store, _) = await started()
        let selected = try #require(store.navigation.selectedID)
        await store.leave(selected)
        #expect(store.navigation.selectedID != selected && store.navigation.selectedID != nil)
    }
    /// Pin and mute come from the server, also when a conversation changes elsewhere.
    @Test func upsertedConversationsTakeTheServersPinAndMute() async throws {
        let (store, _) = await started()
        var known = try #require(store.rooms.conversations.first { $0.pinned })
        known.name = "Renamed"
        known.pinned = false
        known.muted = true
        store.apply(.conversationUpserted(known))
        let updated = try #require(room(store, known.id))
        #expect(updated.name == "Renamed" && !updated.pinned && updated.muted)
    }
}
