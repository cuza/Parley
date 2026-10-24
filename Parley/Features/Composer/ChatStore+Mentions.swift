import Foundation
import ParleyDomain

extension ChatStore {
    /// People who can be @-mentioned: the conversation's full member list once loaded, else the members it came with; never me.
    func mentionCandidates(_ conversation: ConversationID) -> [Person] {
        (rooms.members[conversation] ?? self.conversation(conversation)?.members ?? []).filter { $0.id != me.id }
    }
    /// The composer's @ list: @all first in a space, as Google Chat offers it there and not in direct messages.
    func mentionSuggestions(_ conversation: ConversationID) -> [Person] {
        (self.conversation(conversation)?.kind == .space ? [.everyone] : []) + mentionCandidates(conversation)
    }
    /// Asks the server for the @ list's sections beyond the members, for `text` (what follows "@"): the conversation's
    /// apps, people in the directory, and Drive files (recent ones for "@" alone). The latest query wins; a failure
    /// leaves that section empty, and the list shows the others.
    func searchMentionResults(_ conversation: ConversationID, _ text: String) {
        lookups.appQueries[conversation] = text
        coalesce("apps/" + conversation.rawValue) {
            let query = self.lookups.appQueries[conversation] ?? ""
            let found = (try? await self.backend.searchApps(in: conversation, matching: query)) ?? []
            if query == self.lookups.appQueries[conversation] {
                self.lookups.apps[conversation] = Found(query: query, items: found)
            }
        }
        lookups.mentionQuery = text
        coalesce("directory-search") {
            let query = self.lookups.mentionQuery
            let found = (try? await self.backend.searchDirectory(matching: query)) ?? []
            if query == self.lookups.mentionQuery {
                self.lookups.directoryPeople = Found(query: query, items: found.filter { $0.id != self.me.id })
            }
        }
        coalesce("drive-search") {
            let query = self.lookups.mentionQuery
            let found = (try? await self.backend.searchDriveFiles(matching: query)) ?? []
            if query == self.lookups.mentionQuery { self.lookups.driveFiles = Found(query: query, items: found) }
        }
    }
}
