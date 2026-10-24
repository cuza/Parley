import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Edit ▸ Undo and Redo for the quick changes: the opposite change goes to Google through the same action, a refused
/// change leaves nothing to undo, and the changes that ask first offer no undo.
@MainActor struct UndoTests {
    private static let message = Message.fixture("hi", id: "m1", in: "general")

    /// A started store whose quick changes register on a fresh undo manager.
    private func undoable() async -> (ChatStore, FakeBackend, UndoManager) {
        let (store, fake) = await started()
        let manager = UndoManager()
        store.undoManager = { manager }
        return (store, fake, manager)
    }
    private func room(_ store: ChatStore, _ id: ConversationID) -> Conversation? {
        store.rooms.conversations.first { $0.id == id }
    }
    private func section(_ store: ChatStore, named name: String) async -> SidebarSection? {
        await store.createSection(name, moving: nil)
        return store.rooms.sections.first { $0.name == name }
    }

    /// Each one's name as the menu shows it after Undo, and the call its undo sends to Google.
    @Test(arguments: [
        ("Pin", "unpin launch"), ("Unpin", "pin launch"), ("Mute", "unmute launch"), ("Unmute", "mute launch"),
        ("Hide", "unhide general"), ("Mark as Unread", "read launch"), ("Star", "unstar m1"), ("Unstar", "star m1"),
        ("Pin to Board", "unpin m1"), ("Follow Thread", "unfollow g1"), ("Unfollow Thread", "follow g1"),
    ])
    func aQuickChangeIsUndoneThroughGoogle(name: String, undone: String) async {
        let (store, fake, manager) = await undoable()
        switch name {
        case "Pin", "Unpin": await store.setSidebarPinned(name == "Pin", "launch")
        case "Mute", "Unmute": await store.setMuted(name == "Mute", "launch")
        case "Hide": await store.hide("general")
        case "Mark as Unread": await store.markUnread("launch")
        case "Star", "Unstar": await store.setStarred(name == "Star", Self.message)
        case "Pin to Board": await store.setBoardPinned(true, Self.message)
        default: await store.setFollowing(name == "Follow Thread", for: "g1")
        }
        #expect(manager.undoActionName == name)
        manager.undo()
        await eventually {
            undone == "read launch" ? await fake.markedRead.last == "launch" : await fake.changes.last == undone
        }
        #expect(manager.redoActionName == name && !manager.canUndo)
    }
    @Test func undoAndRedoMakeTheChangeAgainEachTime() async {
        let (store, fake, manager) = await undoable()
        await store.setMuted(true, "launch")
        manager.undo()
        await eventually { room(store, "launch")?.muted == false }
        manager.redo()
        await eventually { room(store, "launch")?.muted == true }
        #expect(await fake.changes == ["mute launch", "unmute launch", "mute launch"])
        #expect(manager.undoActionName == "Mute" && !manager.canRedo)
        manager.undo()
        await eventually { await fake.changes.count == 4 }
        #expect(await fake.changes.last == "unmute launch")
    }
    @Test func aHiddenConversationComesBackAndUnhidingIsUndoneToo() async {
        let (store, fake, manager) = await undoable()
        await store.hide("general")
        manager.undo()
        await eventually { room(store, "general") != nil }
        #expect(await fake.changes == ["hide general", "unhide general"])
        await store.unhide("general")  // nothing to unhide: nothing changes, and Redo Hide stays
        #expect(manager.redoActionName == "Hide")
        manager.redo()
        await eventually { room(store, "general") == nil }
        await store.unhide("general")
        #expect(manager.undoActionName == "Unhide")
    }
    @Test func markAsReadShowsAtOnceAndIsUndoneAsUnread() async {
        let (store, fake, manager) = await undoable()
        await store.markUnread("launch")
        manager.removeAllActions()
        await store.markAsRead("launch")
        #expect(room(store, "launch")?.unread == 0 && manager.undoActionName == "Mark as Read")
        manager.undo()
        await eventually { room(store, "launch")?.unread == 1 }
        #expect(await fake.changes.last == "unread launch")
    }
    @Test func aNotificationLevelGoesBackToTheOneBefore() async {
        let (store, fake, manager) = await undoable()
        await store.setNotificationLevel(.all, "launch")
        manager.removeAllActions()
        await store.setNotificationLevel(.off, "launch")
        #expect(manager.undoActionName == "Change Notifications")
        manager.undo()
        await eventually { room(store, "launch")?.notificationLevel == .all }
        #expect(await fake.changes.last == "level all launch")
    }
    @Test func sectionRenamesAndMovesAreUndone() async throws {
        let (store, fake, manager) = await undoable()
        let first = try #require(await section(store, named: "Projects"))
        let second = try #require(await section(store, named: "Clients"))
        await store.renameSection(first, to: "Work")
        #expect(manager.undoActionName == "Rename Section")
        manager.undo()
        await eventually { await fake.sidebarSections().first { $0.key == first.key }?.name == "Projects" }
        #expect(store.rooms.sections.first { $0.key == first.key }?.name == "Projects")
        await store.moveSection(second, up: true)
        #expect(manager.undoActionName == "Move Section Up")
        manager.undo()
        await eventually { await fake.sidebarSections().first { $0.key == second.key }?.position == second.position }
        #expect(store.rooms.sections.first { $0.key == second.key }?.position == second.position)
    }
    @Test func aRefusedChangeLeavesNothingToUndo() async {
        let (store, fake, manager) = await undoable()
        await fake.simulateChangeFailure()
        await store.setMuted(true, "launch")
        #expect(store.toast != nil && !manager.canUndo)
    }
    @Test func aRefusedUndoSaysSoAndLeavesNothingToRedo() async {
        let (store, fake, manager) = await undoable()
        await store.setMuted(true, "launch")
        await fake.simulateChangeFailure()
        manager.undo()
        await eventually { store.toast != nil }
        #expect(room(store, "launch")?.muted == true && !manager.canUndo && !manager.canRedo)
    }
    /// Leaving, blocking, deleting and taking roles away ask first and stay done; reading by opening isn't the user's change.
    @Test func changesThatAskFirstOfferNoUndo() async throws {
        let (store, _, manager) = await undoable()
        await store.leave("general")
        await store.block(person: "maria", report: false)
        await store.setRole(.owner, for: "alex", in: "launch")
        await store.removeMember("alex", from: "launch")
        await store.deleteSection(try #require(await section(store, named: "Projects")))
        await store.markRead("launch")
        #expect(!manager.canUndo)
    }
}
