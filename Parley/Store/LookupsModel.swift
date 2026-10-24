import Foundation
import ParleyDomain

/// What the server answered to lookups the composer and timeline ask for: custom emoji, the @ list's apps, people and
/// Drive files, slash commands, people's card details and who reacted. Filled by `ChatStore`'s actions, which hold the
/// backend; times come in as arguments.
@MainActor @Observable final class LookupsModel {
    /// The organisation's custom emoji, for the picker and `:shortcode` suggestions; see `ChatStore.loadCustomEmoji`.
    var customEmoji: [CustomEmoji] = []
    @ObservationIgnored var customEmojiLoad: Task<Void, Never>?
    @ObservationIgnored var customEmojiQuery = ""
    @ObservationIgnored var customEmojiAsked: ContinuousClock.Instant?
    /// The @ list's answers from the server for the latest query (`ChatStore.searchMentionResults`): each conversation's
    /// own apps, the directory's people, Drive files.
    var apps: [ConversationID: Found<Person>] = [:]
    @ObservationIgnored var appQueries: [ConversationID: String] = [:]
    var directoryPeople = Found<Person>()
    var driveFiles = Found<DriveFile>()
    @ObservationIgnored var mentionQuery = ""  // the last text after "@", for the directory and Drive searches
    /// The conversations' apps' slash commands found so far, for the composer's "/" list; see `ChatStore.loadSlashCommands`.
    var slashCommands: [ConversationID: [SlashCommand]] = [:]
    @ObservationIgnored var slashQueries: [ConversationID: Set<String>] = [:]
    /// What people's cards add to their names, by email, read once per session (`ChatStore.cardDetails(of:)`).
    @ObservationIgnored var personCards: [String: Task<PersonCardDetails, Never>] = [:]
    @ObservationIgnored var reactors: [MessageID: [Reaction: [Person]]] = [:]  // see `ChatStore.reactorsLine`

    /// Whether to read the custom emoji list now: not while a read runs, and after a failed one at most every 30 seconds,
    /// as a view asks each time it draws.
    func shouldLoadCustomEmoji(at time: ContinuousClock.Instant) -> Bool {
        customEmojiLoad == nil && (customEmojiAsked.map { time - $0 > .seconds(30) } ?? true)
    }
    /// Adds the searched emoji not known yet, after the ones already listed.
    func addCustomEmoji(_ found: [CustomEmoji]) {
        let known = Set(customEmoji.map(\.id))
        let new = found.filter { !known.contains($0.id) }
        if !new.isEmpty { customEmoji += new }
    }
    /// Records that `query` is being asked in `conversation`; false when it was asked already. A bare "/" starts over.
    func startSlashQuery(_ query: String, in conversation: ConversationID) -> Bool {
        if query.isEmpty { slashQueries[conversation] = [] }
        return slashQueries[conversation, default: []].insert(query).inserted
    }
    /// A query's commands join the list, without repeating one already there; a bare "/" replaces it.
    func addSlashCommands(_ found: [SlashCommand], for query: String, in conversation: ConversationID) {
        let known = query.isEmpty ? [] : slashCommands[conversation] ?? []
        slashCommands[conversation] =
            known + found.filter { new in !known.contains { $0.appID == new.appID && $0.id == new.id } }
    }
    /// Stops the reads still running, before the model is dropped.
    func cancel() {
        customEmojiLoad?.cancel()
        personCards.values.forEach { $0.cancel() }
    }
}
