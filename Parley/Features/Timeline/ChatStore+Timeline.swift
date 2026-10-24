import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    func timeline(_ conversation: ConversationID, thread: ThreadID? = nil) -> [Message] {
        history.timeline(conversation, thread: thread, scope: key(conversation, thread))
    }
    /// A page already on its way is waited for, not skipped: a caller paging back (to reach an old message) must see it land.
    /// `quietly`: a background load (a Home preview) logs a failure instead of alerting.
    func load(_ id: ConversationID, thread: ThreadID? = nil, older: Bool = false, quietly: Bool = false) async {
        let scope = key(id, thread)
        if let running = history.pageLoads[scope] {
            await running.value
            return
        }
        guard older || !history.loaded.contains(scope) else { return }
        // Cleared by the load itself, before anyone waiting on it resumes, so the next call starts a new page.
        let task = Task {
            await fetchPage(id, thread: thread, older: older, quietly: quietly)
            history.pageLoads[scope] = nil
            history.loading.remove(scope)
        }
        history.pageLoads[scope] = task
        history.loading.insert(scope)
        await task.value
    }
    /// The page around `message` replaces the conversation's timeline; a page already loading lands first.
    func loadAround(_ message: MessageID, in id: ConversationID) async {
        let scope = key(id, nil)
        if let running = history.pageLoads[scope] { await running.value }
        // A page load like any other, so a load started meanwhile waits for it instead of racing it.
        let task = Task {
            let known = history.shownSent(id, thread: nil)
            do {
                let page = try await backend.messages(around: message, in: id)
                let gone = known.subtracting(page.messages.map(\.id))
                history.messages.removeAll { gone.contains($0.id) }
                page.messages.forEach(upsert)
                history.landed(scope, hasMore: page.hasMore)
                history.extendWindow(id, page)
            } catch { report(error) }
            history.pageLoads[scope] = nil
            history.loading.remove(scope)
        }
        history.pageLoads[scope] = task
        history.loading.insert(scope)
        await task.value
    }
    /// The timeline neared the bottom of a detached window: the next newer page, until the window meets the newest messages.
    func loadNewerIfNeeded(_ id: ConversationID) async {
        guard history.detached.contains(id), !history.newerLoads.contains(id) else { return }
        history.newerLoads.insert(id)
        defer { history.newerLoads.remove(id) }
        do {
            let page = try await backend.newerMessages(in: id)
            page.messages.forEach(upsert)
            history.extendWindow(id, page)
        } catch { report(error) }
    }
    /// The scroll-down button, or a send, from a detached window: the newest messages again.
    func returnToNewest(_ id: ConversationID) async {
        history.attach(id)
        history.loaded.remove(key(id, nil))
        await load(id)
    }
    private func fetchPage(_ id: ConversationID, thread: ThreadID?, older: Bool, quietly: Bool = false) async {
        let scope = key(id, thread)
        let known = history.shownSent(id, thread: thread)
        do {
            let page = try await backend.messages(
                in: id, thread: thread, before: older ? timeline(id, thread: thread).first?.createdAt : nil)
            if !older {
                // The newest page replaces what was shown; a message that arrived during the request isn't in it, and stays.
                let kept = known.subtracting(page.messages.map(\.id))
                history.messages.removeAll { kept.contains($0.id) }
                if thread == nil { history.attach(id) }
            }
            page.messages.forEach(upsert)
            history.landed(scope, hasMore: page.hasMore)
            persist()
        } catch  where quietly {
            log.error("Background load failed: \(Redaction.redact(error.localizedDescription), privacy: .public)")
        } catch { report(error) }
    }
    /// The timeline neared its top: load one older page, one request at a time per timeline. A page already on its
    /// way is waited for first, not a reason to drop the request: a reload of the newest page (reopening the
    /// conversation) lands the same rows, so the timeline would never ask again.
    func loadOlderIfNeeded(_ id: ConversationID, thread: ThreadID? = nil) async {
        let scope = key(id, thread)
        if let running = history.pageLoads[scope] { await running.value }
        guard history.hasMore.contains(scope), !history.loading.contains(scope) else { return }
        await load(id, thread: thread, older: true)
    }
    /// Errors stay with the caller: a missing thumbnail shouldn't raise the store-wide error.
    /// A file not sent yet (the local echo) is read from disk.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data {
        if let file = attachment.url, file.isFileURL {
            return try await Task.detached { try Data(contentsOf: file, options: .mappedIfSafe) }.value
        }
        return try await backend.attachmentData(attachment, thumbnail: thumbnail)
    }
}
