import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    /// An event from Google: each family has its own handler. Everything but the live ones (reactions, typing, presence,
    /// read receipts, my status) goes in the launch cache.
    func apply(_ event: ChatEvent) {
        if case .connectionChanged(let state) = event {
            if state != .connected { connectedSince = nil } else if connection != .connected { connectedSince = now() }
            if state == .reconnecting, connection != .reconnecting { reconnects += 1 }
        } else {
            lastEventAt = now()
        }
        switch event {
        case .reacted, .activityChanged, .typingChanged, .readReceiptsChanged, .presenceChanged, .ownStatusChanged:
            applyLive(event)
            return
        case .messageUpserted, .messageDeleted, .historyCleared:
            applyMessageEvent(event)
        case .conversationUpserted, .conversationRemoved, .conversationViewed, .unreadThreadsChanged,
            .conversationActivity,
            .conversationMarkedUnread, .readStateChanged:
            applyConversationEvent(event)
        case .threadFollowChanged, .threadViewed, .threadMarkedUnread, .homeRefreshed:
            applyThreadEvent(event)
        case .draftChanged(let draft):
            draftChanged(draft)
        case .draftDeleted(let id):
            draftDeleted(id)
        case .connectionChanged, .resync, .blocksChanged, .dndSchedulesChanged:
            applyAccountEvent(event)
        }
        persist()
    }

    // MARK: Live events, not cached

    private func applyLive(_ event: ChatEvent) {
        switch event {
        case .reacted(let id, let emoji, let person, let added):
            reacted(id, emoji: emoji, by: person, added: added)
        case .activityChanged(let id, let thread, let person, let label):
            for scope in Set([key(id, nil), key(id, thread)]) {
                presence.activities[scope] = label.map { PresenceModel.Activity(person: person, label: $0, at: now()) }
            }
        case .typingChanged(let id, let thread, let person, let isTyping):
            if isTyping {
                presence.typing[key(id, thread), default: [:]][person] = now()
                markActive(person)
            } else {
                presence.typing[key(id, thread)]?[person] = nil
            }
        case .readReceiptsChanged(let id, let reads, let enabled):
            if enabled == false {
                presence.receiptsOff.insert(id)
                presence.readReceipts[id] = nil
                return
            }
            if enabled == true { presence.receiptsOff.remove(id) }
            if !presence.receiptsOff.contains(id) {
                presence.readReceipts[id, default: [:]].merge(reads, uniquingKeysWith: max)
            }
        case .presenceChanged(let person, let state, let status):
            presence.customStatus[person] = status
            if let state {
                presence.availability[person] = state
                presence.fetched[person] = now()
            } else if presence.availability[person] == .doNotDisturb {  // DND over: ask again
                presence.availability[person] = nil
                presence.fetched[person] = nil
            }
        case .ownStatusChanged(let status):
            ownStatus = status
        default: break
        }
    }
    private func reacted(_ id: MessageID, emoji: String, by person: PersonID, added: Bool) {
        // ponytail: only reactions to my messages loaded here notify; fetch the message if older ones go unannounced.
        if !added { notifiedReactions.remove("\(id)#\(person)#\(emoji)") }  // added again later, it's news again
        let target = history.messages.first { $0.id == id }
        let whose = target == nil ? "not history.loaded" : target?.sender.id == me.id ? "mine" : "someone else's"
        log.notice(
            "reaction pushed: \(added ? "added" : "removed", privacy: .public), message \(whose, privacy: .public)")
        guard added, let message = target,
            let notification = NotificationPolicy.reaction(
                emoji,
                by: self.person(person, in: message.conversationID)
                    ?? Person(id: person, name: name(of: person, in: message.conversationID)),
                to: message, in: conversation(message.conversationID), me: me.id,
                openConversation: navigation.selectedID,
                openThread: navigation.threadID, timelineShown: navigation.shortcut == nil, appActive: isAppActive(),
                settings: notificationSettings()),
            notifiedReactions.insert(notification.id).inserted
        else { return }
        notifier?.post(notification)
    }

    // MARK: Messages

    private func applyMessageEvent(_ event: ChatEvent) {
        switch event {
        case .messageUpserted(let message):
            messageArrived(message)
        case .messageDeleted(let id):
            // A thread's first message takes the thread with it, as Google Chat deletes it; Google sends only this one.
            let thread = ThreadID(head: id)  // in case it was a thread's first message
            history.messages.removeAll { $0.id == id || $0.threadID == thread }
            rooms.homeThreads.removeAll { $0.id == thread }
            if navigation.threadID == thread { navigation.setPane(nil) { $0.closeThread() } }
        case .historyCleared(let id, let time):
            history.messages.removeAll { $0.conversationID == id && $0.createdAt <= time }
            rooms.homeThreads.removeAll { $0.conversationID == id && $0.latest.createdAt <= time }
            if let room = conversation(id), (room.activity ?? .distantPast) <= time {
                apply(.readStateChanged(id, unread: 0))
            }
        default: break
        }
    }
    private func messageArrived(_ message: Message) {
        let isNew = !history.messages.contains { $0.id == message.id }
        upsert(message)
        // A pin posts a service line: the board on screen reads again.
        if isNew, message.isSystem, rooms.pinned[message.conversationID] != nil {
            coalesce("rooms.pinned/" + message.conversationID.rawValue) {
                await self.loadPinned(message.conversationID)
            }
        }
        // A new message changes the threads listed on screen (Ask Gemini's home, the Threads pane): they read again.
        // ponytail: one read per new message; debounce if a busy room with its Threads pane open makes this chatty.
        if isNew, message.conversationID == navigation.selectedID,
            history.threadSummaries[message.conversationID] != nil,
            navigation.pane(nil).threads || selected?.app == .gemini
        {
            coalesce("threads/" + message.conversationID.rawValue) { await self.loadThreads(message.conversationID) }
        }
        // A newer reply in a thread Home lists moves its row up.
        // Threads already listed; a reply in another one re-reads Home's threads (checkFollowed, below).
        if let thread = message.threadID, let index = rooms.homeThreads.firstIndex(where: { $0.id == thread }),
            message.createdAt > rooms.homeThreads[index].latest.createdAt
        {
            rooms.homeThreads[index].latest = message
            rooms.homeThreads[index].time = max(rooms.homeThreads[index].time, message.createdAt)
            if message.sender.id != me.id, !(navigation.shortcut == .home && navigation.threadID == thread) {
                rooms.homeThreads[index].unread = true
            }
        }
        guard isNew else { return }
        // A new reply in the thread open on screen is read as it arrives.
        if let thread = message.threadID, isAppActive(),
            (thread == navigation.threadID && message.conversationID == navigation.selectedID)
                || navigation.pane(message.conversationID).thread == thread
        {
            coalesce("readThread/" + thread.rawValue) { await self.readThread(thread) }
        }
        if message.sender.id != me.id { someoneSent(message) }
    }
    /// A new message from someone else: their typing ends, and it may notify, count as unread, or be read at once.
    private func someoneSent(_ message: Message) {
        // A message ends its sender's typing, and they're evidently here.
        for scope in presence.typing.keys where scope.hasPrefix(message.conversationID.rawValue + "/") {
            presence.typing[scope]?[message.sender.id] = nil
        }
        if now().timeIntervalSince(message.createdAt) < PresenceModel.presenceTTL { markActive(message.sender.id) }
        if !announce(message), let thread = message.threadID, !followed.contains(thread),
            let level = conversation(message.conversationID)?.notificationLevel,
            level.notifies(head: false, followed: true, mentioned: false),
            !level.notifies(head: false, followed: false, mentioned: false)
        {
            checkFollowed(message)
        } else if let thread = message.threadID, !rooms.homeThreads.contains(where: { $0.id == thread }) {
            checkFollowed(nil)  // Home may list it now
        }
        // Only a fresh message is unread: a reaction or edit pushes an old message the user has long since read.
        // The conversation on screen counts too while Parley is in the background: `appBecameActive` reads it.
        if !message.isSystem, message.threadID == nil, message.conversationID != openConversation || !isAppActive(),
            now().timeIntervalSince(message.createdAt) < Self.unreadWindow,
            let index = conversationIndex(message.conversationID)
        {
            rooms.conversations[index].unread += 1
        }
        // ponytail: one read receipt per pushed message; debounce if busy rooms make this chatty.
        if message.conversationID == openConversation, isAppActive(), !heldUnread.contains(message.conversationID) {
            coalesce("read/" + message.conversationID.rawValue) { await self.markRead(message.conversationID) }
        }
    }

    // MARK: Conversations

    private func applyConversationEvent(_ event: ChatEvent) {
        switch event {
        case .conversationUpserted(let room) where room.hidden != nil:  // hidden here or elsewhere: off the sidebar, into Settings' list
            apply(.conversationRemoved(room.id))
            rooms.hidden.insert(room, at: 0)
        case .conversationUpserted(let room):  // changed elsewhere; a new one is the most recent
            conversationChanged(room)
        case .conversationRemoved(let id):
            conversationRemoved(id)
        case .conversationViewed(let id, let time):
            conversationViewed(id, at: time)
        case .unreadThreadsChanged(let id, let count):
            if let index = conversationIndex(id), (rooms.conversations[index].unreadThreads ?? 0) != count {
                rooms.conversations[index].unreadThreads = count > 0 ? count : nil
            }
        case .conversationActivity(let id, let time):
            if let index = conversationIndex(id), time > rooms.conversations[index].activity ?? .distantPast {
                rooms.conversations[index].activity = time
            }
        case .conversationMarkedUnread(let id):
            if let index = conversationIndex(id), rooms.conversations[index].unread == 0 {
                rooms.conversations[index].unread = 1
            }
        case .readStateChanged(let id, let count):
            if let index = conversationIndex(id) { rooms.conversations[index].unread = count }
            if count == 0 { notifier?.clear(conversation: id) }  // read here or on another device
        default: break
        }
    }
    private func conversationChanged(_ room: Conversation) {
        var room = room
        rooms.hidden.removeAll { $0.id == room.id }
        // The open conversation stays read: its server read state can trail what is on screen (my own send, a membership change).
        if room.id == openConversation, room.unread > 0, isAppActive(), !heldUnread.contains(room.id) {
            room.unread = 0
            Task { await markRead(room.id) }
        }
        if let index = conversationIndex(room.id) {
            rooms.conversations[index] = room
        } else {
            rooms.conversations.insert(room, at: 0)
        }
        // Members or roles may have changed: what is on screen is read again.
        if rooms.members[room.id] != nil { Task { await reloadMembers(room.id) } }
        if rooms.permissions[room.id] != nil { Task { await loadPermissions(room.id) } }
    }
    private func conversationRemoved(_ id: ConversationID) {
        rooms.remove(id)
        history.messages.removeAll { $0.conversationID == id }
        notifier?.clear(conversation: id)
        // Gone, so no place to go back or forward to.
        navigation.forget(id)
        guard navigation.selectedID == id else { return }
        drafting.editing = drafting.editing.filter { !$0.key.hasPrefix(id.rawValue + "/") }
        drafting.held = drafting.held.filter { !$0.key.hasPrefix(id.rawValue + "/") }
        navigation.setPane(nil) { $0.closeThread() }
        if navigation.shortcut == nil {  // it was on screen: the next one opens in its place
            navigation.selectedID = rooms.conversations.first?.id
            if let next = navigation.selectedID { Task { await select(next) } }
        } else {
            navigation.selectedID = nil
        }  // behind Home: Home stays, and nothing else opens or is read
    }
    /// Read elsewhere up to `time`: unread only if a message newer than that has come, as Google Chat compares its newest
    /// message with the read time. Activity is only a stand-in when none is loaded: a reaction or edit moves it.
    private func conversationViewed(_ id: ConversationID, at time: Date) {
        guard let room = conversation(id), room.unread > 0 else { return }
        let newest =
            history.messages.lazy.filter { $0.conversationID == id && $0.threadID == nil }.map(\.createdAt).max()
            ?? room.activity ?? .distantPast
        log.info(
            "read elsewhere: conversation \(newest <= time ? "read" : "has newer history.messages", privacy: .public)")
        if newest <= time { apply(.readStateChanged(id, unread: 0)) }
    }

    // MARK: Threads and Home

    private func applyThreadEvent(_ event: ChatEvent) {
        switch event {
        case .threadFollowChanged(let thread, let following):
            if following { followed.insert(thread) } else { followed.remove(thread) }
        case .threadViewed(let thread, let time):
            if let index = rooms.homeThreads.firstIndex(where: { $0.id == thread }), rooms.homeThreads[index].unread,
                rooms.homeThreads[index].latest.createdAt <= time
            {
                rooms.homeThreads[index].unread = false
            }
        case .threadMarkedUnread(let thread, let unread):
            if let index = rooms.homeThreads.firstIndex(where: { $0.id == thread }),
                rooms.homeThreads[index].unread != unread
            {
                rooms.homeThreads[index].unread = unread
            }
        case .homeRefreshed:
            checkFollowed(nil)
        default: break
        }
    }

    // MARK: Drafts

    private func draftChanged(_ draft: ServerDraft) {
        let scope = key(draft.conversationID, draft.threadID)
        if drafting.spent.contains(draft.id) { return }  // sent: an echo of an earlier save, not a draft
        if draft.schedule != nil {
            drafting.keepScheduled(draft)
            return
        }
        // Our own save comes back too, possibly after a newer one: only a newer copy counts.
        if let held = drafting.server[scope], held.id == draft.id, held.updatedAt >= draft.updatedAt { return }
        drafting.server[scope] = draft
        // The user typing here wins: their text replaces this at the next save.
        if drafting.edits[scope] == nil, drafting.writes[scope] == nil, !drafting.isEditing(scope) {
            drafting.fill(scope, with: draft)
        }
    }
    private func draftDeleted(_ id: String) {
        drafting.scheduled.removeAll { $0.id == id }  // sent at its time, or cancelled elsewhere
        guard let (scope, held) = drafting.server.first(where: { $0.value.id == id }) else { return }  // ours, or a send's
        drafting.server[scope] = nil
        // Sent or deleted elsewhere: the composer empties, unless it holds text not yet saved.
        if drafting.edits[scope] == nil, drafting.text[scope] == held.text, !drafting.isEditing(scope) {
            drafting.clear(scope)
        }
    }

    // MARK: The connection and the account

    private func applyAccountEvent(_ event: ChatEvent) {
        switch event {
        case .connectionChanged(let state):
            connection = state
            if state != .connected { presence.typing = [:] }  // nobody's typing reaches us now
        case .resync:
            resync()
        case .blocksChanged:
            Task { await loadBlocked() }
        case .dndSchedulesChanged(let schedules):
            if dndSchedules != schedules { dndSchedules = schedules }
        default: break
        }
    }

    // MARK: Notifications

    /// Posts a pushed message's banner when the notification policy allows it; false when it doesn't.
    @discardableResult
    private func announce(_ message: Message) -> Bool {
        let room = conversation(message.conversationID)
        // A call notifies even with its DM on screen, as a phone call would.
        let call = NotificationPolicy.isIncomingCall(message, in: room, me: me.id, now: now())
        let notification = NotificationPolicy.notification(
            for: message, in: room, me: me.id, openConversation: navigation.selectedID,
            openThread: navigation.threadID, timelineShown: navigation.shortcut == nil,
            appActive: !call && isAppActive(), settings: notificationSettings(),
            threadFollowed: message.threadID.map(followed.contains) ?? false
        )
        .map { call ? $0.incomingCall(join: message.attachments.first { $0.kind == .call }?.url) : $0 }
        // Why or why not, for "notifications don't show" reports: nothing here names the conversation or the sender.
        let level = room?.notificationLevel.map { "\($0)" } ?? "unknown"
        let followed = message.threadID.map(followed.contains)
        let kind = message.threadID == nil ? "new thread" : followed == true ? "followed reply" : "unfollowed reply"
        let detail =
            "level \(level), \(kind), muted \(room?.muted ?? false), app active \(isAppActive()), open here \(message.conversationID == navigation.selectedID)"
        if notification == nil {
            log.notice("message pushed: no banner (\(detail, privacy: .public))")
        } else {
            log.notice("message pushed: \(self.notifier == nil ? "no notifier" : "banner", privacy: .public)")
        }
        if let notification { notifier?.post(notification) }
        return notification != nil
    }
    /// The server says Parley missed events: refresh, one at a time (a flapping connection sends a burst).
    private func resync() { coalesce("resync") { do { try await self.refresh() } catch { self.report(error) } } }
    /// A reply in a thread Home doesn't list: re-read the server's followed threads (Home's) so Home shows it, and post the
    /// banner of a `message` whose notification depends on following. One read right away and one `followRecheck` after
    /// the last such reply; a burst between them waits for that one.
    private func checkFollowed(_ message: Message?) {
        if let message { awaitingFollow.append(message) }
        followAsked = .now
        guard followCheck == nil else { return }
        followCheck = Task {
            defer { followCheck = nil }
            var read: ContinuousClock.Instant?
            while read.map({ $0 < followAsked + followRecheck }) ?? true {
                if read != nil { try? await Task.sleep(until: max(.now, followAsked + followRecheck)) }
                read = .now
                // Google sends Home's threads with the conversation list; only the threads are taken. The list itself stays
                // as Parley has it: a read that started before a hide, mute, pin or pushed message would undo it.
                guard (try? await backend.conversations()) != nil else { continue }
                let threads = await backend.homeThreads()
                rooms.homeThreads = threads
                followed.formUnion(threads.map(\.id))
                let found = awaitingFollow.filter { $0.threadID.map(followed.contains) == true }
                awaitingFollow.removeAll { message in found.contains { $0.id == message.id } }
                found.forEach { announce($0) }
            }
            awaitingFollow = []
        }
    }
}
