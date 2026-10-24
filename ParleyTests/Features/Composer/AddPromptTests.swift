import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Before a mention adds someone, Parley asks as Google Chat does ("Add to this conversation?"): Add and Send invites
/// them, Send Without Adding only names them, Cancel keeps the draft.
@MainActor struct AddPromptTests {
    static let sam = FakeBackend.directoryPerson
    private func drafted() async -> (FakeBackend, ChatStore, String) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.loadMembers("design")
        await store.loadPermissions("design")
        store.setDraft(
            "@Sam Okafor hi", formatting: [TextStyleRange(style: .mention(userID: Self.sam.id), start: 0, length: 11)],
            conversation: "design", thread: nil)
        return (fake, store, store.key("design", nil))
    }
    @Test func sendAsksFirstAndCancelKeepsTheDraft() async {
        let (fake, store, scope) = await drafted()
        await store.send(conversation: "design")
        #expect(store.drafting.addPrompts[scope] == ["Sam Okafor"])
        #expect(await fake.sentDrafts.isEmpty && store.drafting.text[scope] == "@Sam Okafor hi")
    }
    @Test func addAndSendInvitesThem() async throws {
        let (fake, store, scope) = await drafted()
        await store.send(conversation: "design", adding: true)
        #expect(try #require(await fake.sentDrafts.last).outsiders == [Self.sam.id: .invite])
        #expect(store.drafting.addPrompts[scope] == nil)
    }
    @Test func sendWithoutAddingOnlyNamesThem() async throws {
        let (fake, store, _) = await drafted()
        await store.send(conversation: "design", adding: false)
        #expect(try #require(await fake.sentDrafts.last).outsiders == [Self.sam.id: .reference])
    }
}
