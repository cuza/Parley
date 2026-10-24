import Foundation
import ParleyDomain

extension ChatStore {
    /// Saves at most once every two seconds, with whatever is current by then: a busy room never starves the save.
    func persist() {
        guard cache != nil, cacheTask == nil else { return }
        cacheTask = Task {
            try? await Task.sleep(for: .seconds(2))
            cacheTask = nil
            guard !Task.isCancelled else { return }
            await save()
        }
    }
    private func snapshot() -> LaunchSnapshot {
        // A message still sending is saved as failed: after a quit, Retry sends it. ponytail: if it reached Google just before
        // the quit, the failed copy shows beside the sent one until deleted.
        let saved = history.messages.map { message in
            var message = message
            if message.delivery == .pending { message.delivery = .failed }
            return message
        }
        let grouped = Dictionary(grouping: saved, by: { key($0.conversationID, $0.threadID) })
        // A composer being edited holds the message's text; its draft is the one the edit put aside.
        var drafts = drafting.text
        var formatting = drafting.formatting
        for (scope, held) in drafting.held {
            drafts[scope] = held.text
            formatting[scope] = held.formatting
        }
        return LaunchSnapshot(
            accountID: me.id.rawValue.isEmpty ? cachedAccountID : me.id, conversations: rooms.conversations,
            messages: grouped.values.flatMap { Array($0.sorted { $0.createdAt < $1.createdAt }.suffix(50)) },
            selectedID: navigation.selectedID, drafts: drafts, draftFormatting: formatting, draftEdits: drafting.edits,
            serverDrafts: drafting.server,
            homeThreads: rooms.homeThreads, customEmoji: lookups.customEmoji)
    }
    private func save() async {
        guard let cache else { return }
        let snapshot = snapshot()
        do {
            try await Task.detached { try cache.save(snapshot) }.value
        } catch {
            self.error = "Couldn’t save the launch cache: \(error.localizedDescription)"
        }
    }
    /// At quit: the pending save can't wait for its delay.
    func flush() {
        cacheTask?.cancel()
        cacheTask = nil
        guard let cache else { return }
        try? cache.save(snapshot())
    }
}
