import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Lookups on their own, without a store or a backend.
@MainActor struct LookupsModelTests {
    private func emoji(_ id: String) -> CustomEmoji { CustomEmoji(id: id, shortcode: id) }
    private func command(_ id: Int64, app: PersonID = "poll") -> SlashCommand {
        SlashCommand(appID: app, appName: "Poll", name: "/c\(id)", id: id)
    }

    @Test func customEmojiIsAskedAgainOnlyAfterThirtySeconds() {
        let lookups = LookupsModel()
        let start = ContinuousClock.now
        #expect(lookups.shouldLoadCustomEmoji(at: start))
        lookups.customEmojiAsked = start
        #expect(!lookups.shouldLoadCustomEmoji(at: start + .seconds(30)))
        #expect(lookups.shouldLoadCustomEmoji(at: start + .seconds(31)))
        lookups.customEmojiLoad = Task {}
        #expect(!lookups.shouldLoadCustomEmoji(at: start + .seconds(60)))  // a read is running
    }
    @Test func searchedEmojiJoinTheListOnce() {
        let lookups = LookupsModel()
        lookups.customEmoji = [emoji("a"), emoji("b")]
        lookups.addCustomEmoji([emoji("b"), emoji("c")])
        #expect(lookups.customEmoji.map(\.id) == ["a", "b", "c"])
    }
    @Test func slashQueriesAreAskedOnceAndABareSlashStartsOver() {
        let lookups = LookupsModel()
        #expect(lookups.startSlashQuery("", in: "space"))
        lookups.addSlashCommands([command(1)], for: "", in: "space")
        #expect(lookups.startSlashQuery("po", in: "space"))
        #expect(!lookups.startSlashQuery("po", in: "space"))
        lookups.addSlashCommands([command(1), command(2)], for: "po", in: "space")
        #expect(lookups.slashCommands["space"]?.map(\.id) == [1, 2])
        #expect(lookups.startSlashQuery("", in: "space"))  // asked again, and its answer replaces the list
        #expect(lookups.slashQueries["space"] == [""])
        lookups.addSlashCommands([command(2)], for: "", in: "space")
        #expect(lookups.slashCommands["space"]?.map(\.id) == [2])
    }
}
