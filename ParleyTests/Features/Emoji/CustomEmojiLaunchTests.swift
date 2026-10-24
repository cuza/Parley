import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// The emoji picker shows the organisation's emoji without waiting for the whole list: the last launch's copy at once,
/// then what this launch reads.
@MainActor struct CustomEmojiLaunchTests {
    static let parrot = CustomEmoji(
        id: "p", shortcode: "party-parrot", imageURL: URL(string: "https://example.invalid/p"))
    static func cache(_ snapshot: LaunchSnapshot) throws -> LaunchCache {
        let cache = LaunchCache(url: URL.temporaryDirectory.appending(path: "parley-cache-\(UUID().uuidString).json"))
        try cache.save(snapshot)
        return cache
    }
    @Test func theLastLaunchsListShowsAtOnce() throws {
        let store = ChatStore(
            backend: FakeBackend(), cache: try Self.cache(LaunchSnapshot(accountID: "me", customEmoji: [Self.parrot])))
        #expect(store.lookups.customEmoji == [Self.parrot])
        #expect(store.customEmojiNow() == [Self.parrot])  // and the read for this launch starts behind it
    }
    /// Google Chat refuses custom emoji where people outside the organisation take part (a reaction answers HTTP 403, a
    /// message loses the emoji): Parley offers none there. A conversation not known to be external offers them.
    @Test func customEmojiAreLeftOutWherePeopleOutsideTheOrganisationTakePart() throws {
        let inside = Conversation.fixture("space/in", name: "In")
        var outside = Conversation.fixture("space/out", name: "Out")
        outside.external = true
        let store = ChatStore(
            backend: FakeBackend(),
            cache: try Self.cache(
                LaunchSnapshot(accountID: "me", conversations: [inside, outside], customEmoji: [Self.parrot])))
        #expect(store.allowsCustomEmoji(in: "space/in") && !store.allowsCustomEmoji(in: "space/out"))
        #expect(store.allowsCustomEmoji(in: "space/unknown"))
    }
    @Test func aCacheFromBeforeTheListDecodes() throws {
        let old = Data(#"{"drafts":{}}"#.utf8)
        #expect(try JSONDecoder().decode(LaunchSnapshot.self, from: old).customEmoji.isEmpty)
    }
    @Test func askingForTheListStartsItsReadWithoutWaiting() async throws {
        let cache = try Self.cache(LaunchSnapshot())
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        await store.start()
        #expect(store.customEmojiNow().isEmpty)
        await eventually { store.lookups.customEmoji == FakeBackend.customEmoji }
        #expect(store.lookups.customEmoji == FakeBackend.customEmoji)
        store.flush()
        #expect(cache.load().customEmoji == FakeBackend.customEmoji)  // kept for the next launch
    }
}
