import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

@MainActor
struct ChatStoreTests {
    @Test func startAdoptsBackendIdentity() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        #expect(store.me == FakeBackend.me)
        #expect(!store.rooms.conversations.isEmpty)
    }
    @Test func retryResendsTheSameLocalID() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.navigation.selectedID)
        await fake.simulateSendFailure()
        store.setDraft("hi", conversation: id, thread: nil)
        await store.send(conversation: id)
        let failed = try #require(store.history.messages.first { $0.delivery == .failed })
        await store.retry(failed)
        let ids = await fake.sentDrafts.map(\.localID)
        #expect(ids.count == 2 && ids[0] == ids[1])
    }
    @Test func reselectingRefetchesHistory() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let id = try #require(store.navigation.selectedID)
        store.history.messages.removeAll()  // the server has messages the store doesn't
        await store.select(id)
        #expect(!store.timeline(id).isEmpty)
    }
    @Test func signedOutStartCanBeRetried() async {
        let fake = FakeBackend()
        await fake.simulateSignedOut()
        let store = ChatStore(backend: fake)
        await store.start()
        #expect(store.connection == .signedOut)
        #expect(store.rooms.conversations.isEmpty)
        await store.start()  // author signed in, then pressed Try again
        #expect(store.me == FakeBackend.me)
        #expect(!store.rooms.conversations.isEmpty)
    }
    @Test func aCancelledStartIsNotAnErrorAndKeepsTheConnection() async {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let connection = store.connection
        await fake.simulateCancelledConnect()
        await store.start()
        #expect(store.error == nil)
        #expect(store.connection == connection)
    }
    @Test(arguments: [AuthFailure.signInRequired, .bootstrapRedirect(AuthFailure.signInCategory)])
    func aSessionLostMidUseShowsTheExpiredBannerNotAnError(_ failure: AuthFailure) async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.navigation.selectedID)
        await fake.simulateSessionExpiredOnNextSend(failure)
        store.setDraft("hi", conversation: id, thread: nil)
        await store.send(conversation: id)
        #expect(store.error == nil)
        #expect(store.sessionExpired)
    }
    @Test func showInChatHighlightsASharedItemsMessageOrOpensItsThread() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let id = try #require(store.navigation.selectedID)
        let message = try #require(store.timeline(id).last)
        await store.showShared(
            SharedContent.Item(
                attachment: Attachment(name: "a", kind: .file), date: .now, sender: "", messageID: message.id), in: id)
        #expect(store.history.highlightedID == message.id)
        let reply: MessageID = "\(id)/t1/m2"  // a reply: its message differs from its topic
        await store.showShared(
            SharedContent.Item(
                attachment: Attachment(name: "b", kind: .file), date: .now, sender: "", messageID: reply), in: id)
        #expect(store.navigation.threadID == "\(id)/t1/t1" && store.history.highlightedID == reply)
    }
    @Test func aChatLinkOpensItsConversationOrIsLeftToTheBrowser() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let other = try #require(store.rooms.conversations.last { $0.id != store.navigation.selectedID })
        #expect(await store.open(ChatLink(conversations: ["dm/unknown", other.id])))
        #expect(store.navigation.selectedID == other.id)
        #expect(await !store.open(ChatLink(conversations: ["space/not-in-the-sidebar"])))
        #expect(store.navigation.selectedID == other.id)
    }
    @Test func pushedMessagesCountAsUnreadOnlyElsewhereAndOnce() async throws {
        let store = ChatStore(backend: FakeBackend())
        store.isAppActive = { true }  // on screen and in front; in the background it counts (DockMenuTests)
        await store.start()
        let selected = try #require(store.navigation.selectedID)
        let other = try #require(store.rooms.conversations.first { $0.id != selected })
        let selectedUnread = store.rooms.conversations.first { $0.id == selected }?.unread
        let incoming = Message.fixture("hi", id: "push-1", in: other.id, at: .now)
        store.apply(.messageUpserted(incoming))
        store.apply(.messageUpserted(incoming))  // echo/duplicate
        store.apply(.messageUpserted(.fixture("mine", id: "push-2", from: store.me, in: other.id, at: .now)))
        store.apply(.messageUpserted(.fixture("reply", id: "push-3", in: other.id, thread: "x", at: .now)))
        store.apply(.messageUpserted(.fixture("here", id: "push-4", in: selected, at: .now)))
        #expect(store.rooms.conversations.first { $0.id == other.id }?.unread == other.unread + 1)
        #expect(store.rooms.conversations.first { $0.id == selected }?.unread == selectedUnread)
    }
    @Test func resyncReloadsConversations() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.rooms.conversations.removeAll()
        store.apply(.resync)
        await eventually { !store.rooms.conversations.isEmpty }
        #expect(!store.rooms.conversations.isEmpty)
    }

    @Test func resyncKeepsOpenThreadAndEdit() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let head = try #require(store.history.messages.first { $0.replyCount > 0 })
        await store.select(head.conversationID)
        await store.openThread(head)
        let own = try #require(store.timeline(head.conversationID).last { $0.sender.id == store.me.id })
        store.edit(own)
        store.rooms.conversations.removeAll()
        store.apply(.resync)
        await eventually { !store.rooms.conversations.isEmpty }
        #expect(store.navigation.threadID == ThreadID(head: head.id))
        #expect(store.editingID(own.conversationID, thread: own.threadID) == own.id)
    }

    /// A message jumped to is outlined for a moment, as Telegram flashes it, then goes back to normal by itself.
    @Test func aHighlightFadesByItself() async throws {
        let store = ChatStore(backend: FakeBackend())
        store.history.highlightDuration = .milliseconds(400)  // margins of 200 ms each way: a busy Mac doesn't flip the result
        store.history.highlightedID = "a"
        try await Task.sleep(for: .milliseconds(200))
        store.history.highlightedID = "b"  // a newer jump restarts the wait
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.history.highlightedID == "b")  // 400 ms after "a", but only 200 after "b"
        await eventually { store.history.highlightedID == nil }
        #expect(store.history.highlightedID == nil)
    }

    /// The timeline is sorted once per change, not on every read, and every change shows: added, edited, removed.
    @Test func aTimelineFollowsEveryChangeToItsMessages() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.rooms.conversations.first).id
        await store.load(room)
        let before = store.timeline(room)
        #expect(store.timeline(room) == before)  // a second read gives the same, in order
        let newest = Message.fixture("hi", id: "\(room)/new", from: store.me, in: room, at: .now.addingTimeInterval(60))
        store.history.messages.append(newest)
        #expect(store.timeline(room).last == newest)
        let index = try #require(store.history.messages.firstIndex { $0.id == newest.id })
        store.history.messages[index].text = "edited"
        #expect(store.timeline(room).last?.text == "edited")
        store.history.messages.removeAll { $0.id == newest.id }
        #expect(store.timeline(room) == before)
    }

    /// Marking read happens in the background and is tried again on the next visit: a refusal is logged, not shown.
    @Test func aRefusedReadMarkShowsNoError() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await fake.simulateReadFailure()
        await store.markRead(try #require(store.rooms.conversations.first).id)
        #expect(store.error == nil)
    }

    /// Each composer has its own edit: a thread window's edit is not the main composer's, and leaving a conversation
    /// ends only the edits in the main window, clearing their text so it isn't left behind as a draft.
    @Test func anEditBelongsToItsComposer() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let head = try #require(store.history.messages.first { $0.replyCount > 0 })
        let room = head.conversationID
        await store.select(room)
        var reply = Message.fixture("in the thread", id: "\(room)/mine-reply", from: store.me, in: room, at: .now)
        reply.threadID = ThreadID(head: head.id)
        let main = Message.fixture("in the room", id: "\(room)/mine-main", from: store.me, in: room, at: .now)
        store.history.messages += [reply, main]
        store.edit(reply)  // in the thread's own window
        #expect(
            store.editingID(room, thread: ThreadID(head: head.id)) == reply.id
                && store.editingID(room, thread: nil) == nil)
        store.setDraft("a new message", conversation: room, thread: nil)
        await store.send(conversation: room)  // Return in the main composer sends, it doesn't edit the reply
        #expect(store.timeline(room).contains { $0.text == "a new message" })
        #expect(
            store.history.messages.first { $0.id == reply.id }?.text == "in the thread"
                && store.editingID(room, thread: ThreadID(head: head.id)) == reply.id)
        store.edit(main)
        let other = try #require(store.rooms.conversations.first { $0.id != room }).id
        await store.select(other)
        #expect(
            store.editingID(room, thread: nil) == nil && store.drafting.text[store.key(room, nil), default: ""].isEmpty)
        #expect(
            store.editingID(room, thread: ThreadID(head: head.id)) == reply.id
                && store.drafting.text[store.key(room, ThreadID(head: head.id))] == "in the thread")
    }

    /// Popping the thread out closes the pane and names the thread for its own window, whose timeline keeps its replies.
    @Test func detachingTheOpenThreadClosesThePaneAndKeepsItsReplies() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let head = try #require(store.history.messages.first { $0.replyCount > 0 })
        await store.select(head.conversationID)
        await store.openThread(head)
        let replies = store.timeline(head.conversationID, thread: ThreadID(head: head.id)).count
        #expect(
            store.detachThread(in: head.conversationID)
                == ThreadRef(conversation: head.conversationID, thread: ThreadID(head: head.id)))
        #expect(store.navigation.threadID == nil)
        #expect(store.timeline(head.conversationID, thread: ThreadID(head: head.id)).count == replies && replies > 0)
        #expect(store.detachThread(in: head.conversationID) == nil)  // nothing open
    }
    /// macOS restores a thread or conversation window by its ids, even one the signed-in account doesn't have
    /// (another account's, or one it left): it should close, not ask the server for it.
    @Test func aRestoredWindowKnowsWhetherItsConversationIsThisAccounts() async throws {
        let store = ChatStore(backend: FakeBackend())
        #expect(store.hasConversation("dm/elsewhere") == nil)  // the list hasn't come: wait
        await store.start()
        let room = try #require(store.rooms.conversations.first).id
        #expect(store.hasConversation(room) == true)
        #expect(store.hasConversation("dm/elsewhere") == false)
    }

    /// Ask Gemini's home lists its sessions as they change: a new answer moves its session to the top.
    @Test func askGeminisHomeFollowsNewAnswers() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let gemini = try #require(store.rooms.conversations.first { $0.app == .gemini }).id
        await store.select(gemini)
        await store.loadThreads(gemini)
        #expect(store.history.threadSummaries[gemini]?.first?.id == "gs1")
        await fake.simulateIncoming(
            .fixture(
                "One more thing", id: "gs2r2", from: .fixture("g", name: "Gemini"), in: gemini, thread: "gs2", at: .now)
        )
        await eventually { store.history.threadSummaries[gemini]?.first?.id == "gs2" }
        #expect(store.history.threadSummaries[gemini]?.first?.id == "gs2")
    }

    /// Moving on before a conversation's messages land (⌥↓ through unread ones, ⌘1…9) leaves it unread: only the one
    /// that stays on screen is read, on the server too.
    @Test func aConversationPassedThroughStaysUnread() async throws {
        let fake = FakeBackend(latency: .milliseconds(150))
        let store = ChatStore(backend: fake)
        await store.start()
        let before = await fake.markedRead
        async let passed: Void = store.select("alex")
        try await Task.sleep(for: .milliseconds(40))
        await store.select("maria")
        await passed
        let read = Array(await fake.markedRead.dropFirst(before.count))
        #expect(read == ["maria"])
        #expect(store.navigation.selectedID == "maria")
    }

    /// Hiding or leaving the conversation behind Home (here, or on another device) keeps Home on screen and opens nothing.
    @Test func removingTheConversationBehindHomeStaysOnHome() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.select("general")
        await store.openShortcut(.home)
        let read = await fake.markedRead.count
        store.apply(.conversationRemoved("general"))
        try await Task.sleep(for: .milliseconds(50))  // time for a select or read that must not happen
        #expect(store.navigation.shortcut == .home)
        #expect(await fake.markedRead.count == read)
    }

    @Test func jumpingToAnUnknownConversationAddsIt() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.jump(
            Message.fixture("hit", id: "dm/zz/t1/t1", from: .fixture("u", name: "U"), in: "dm/zz", at: .now))
        #expect(store.selected?.id == "dm/zz")
    }
    @Test func pushIntoTheOpenConversationMarksItReadWhileActive() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { true }
        await store.start()
        let selected = try #require(store.navigation.selectedID)
        let before = await fake.markedRead.count
        store.apply(
            .messageUpserted(
                .fixture("hi", id: "push-9", from: .fixture("maria", name: "Maria"), in: selected, at: .now)))
        await eventually { await fake.markedRead.count > before }
        #expect(await fake.markedRead.count == before + 1)
    }

    /// Seen live: a new group DM showed an unread badge while open, after my own first message, from the pushed sidebar entry.
    @Test func aPushedUpdateToTheOpenConversationKeepsItRead() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { true }
        await store.start()
        var room = try #require(store.selected)
        room.unread = 1
        let before = await fake.markedRead.count
        store.apply(.conversationUpserted(room))
        #expect(store.selected?.unread == 0)
        await eventually { await fake.markedRead.count > before }
        #expect(await fake.markedRead.count == before + 1)
    }

    /// Seen live: a link to the top of a long conversation showed one page's spinner and stopped. The timeline's own
    /// older-page load was in flight, and each page the search asked for returned at once without loading.
    @Test func goingToAnOldMessageWaitsForAnOlderPageAlreadyLoading() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 300, latency: .milliseconds(30)))
        await store.start()
        await store.select("engineering")
        #expect(!store.history.messages.contains { $0.id == "e0" })
        async let timeline: Void = store.loadOlderIfNeeded("engineering")  // the timeline near its top, already loading
        async let search: Void = store.showQuoted("e0", in: "engineering")
        _ = await (timeline, search)
        let loaded = store.timeline("engineering")
        #expect(
            store.history.highlightedID == "e0",
            "oldest \(loaded.first?.id ?? "-"), \(loaded.count) loaded, more: \(store.history.hasMore.contains(store.key("engineering", nil)))"
        )
    }
    @Test func nearingTheTopLoadsOneOlderPageAtATime() async throws {
        let fake = FakeBackend(latency: .milliseconds(100))
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.navigation.selectedID)
        let scope = store.key(id, nil)
        let before = await fake.historyRequests
        store.history.hasMore.insert(scope)
        async let first: Void = store.loadOlderIfNeeded(id)
        async let second: Void = store.loadOlderIfNeeded(id)  // while the first is in flight: dropped
        _ = await (first, second)
        #expect(await fake.historyRequests == before + 1)
        store.history.hasMore.insert(scope)  // the server says there is still more
        await store.loadOlderIfNeeded(id)  // the page landed: the next one goes at once, no cooldown
        #expect(await fake.historyRequests == before + 2)
        store.history.hasMore.remove(scope)
        await store.loadOlderIfNeeded(id)  // nothing more: no request
        #expect(await fake.historyRequests == before + 2)
    }
}

/// The launch cache belongs to one account: the next account on this Mac must not see or send the previous one's.
@MainActor
struct LaunchCacheAccountTests {
    private static func cache() -> LaunchCache {
        LaunchCache(url: URL.temporaryDirectory.appending(path: "parley-cache-\(UUID().uuidString).json"))
    }

    @Test func anotherAccountsCacheIsDiscardedWhenThisAccountConnects() async throws {
        let cache = Self.cache()
        try cache.save(
            LaunchSnapshot(accountID: "someone-else", drafts: ["engineering/timeline": "their unsent draft"]))
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        #expect(!store.drafting.text.isEmpty)  // shown until the server says who this is
        await store.start()
        #expect(store.drafting.text["engineering/timeline"] == nil && store.me == FakeBackend.me)
        store.flush()
        #expect(cache.load().accountID == FakeBackend.me.id)
    }
    /// Signing in as another account in the same run: nothing the first account loaded stays, so Settings can't save its
    /// Do Not Disturb schedules into the second, and Back can't open its conversations.
    @Test func anotherAccountStartsClean() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.select("general")
        await store.select("alex")
        await store.loadDndSchedules()
        await store.loadThreads("general")
        await store.loadPermissions("general")
        #expect(
            store.dndSchedules != nil && store.canGoBack && store.history.threadSummaries["general"] != nil
                && store.rooms.permissions["general"] != nil)
        await fake.simulateAccount(Person(id: "b", name: "B"))
        await store.start()
        #expect(store.me.id == "b")
        #expect(store.dndSchedules == nil)
        #expect(store.navigation.backPlaces.isEmpty && store.navigation.forwardPlaces.isEmpty)
        #expect(store.history.threadSummaries["general"] == nil)
    }
    /// Every stored property is either the account's (cleared when another account connects) or the app's (kept). A new
    /// property fails here until it is put in one list, so `forgetAccount` can't silently miss it.
    @Test func everyStoredPropertyIsClassifiedForAccountSwitches() {
        let names = Set(
            Mirror(reflecting: ChatStore(backend: FakeBackend())).children.compactMap {
                $0.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
            }
        )
        .subtracting(["$observationRegistrar"])
        let classified = ChatStore.accountState.union(ChatStore.appState)
        #expect(names.subtracting(classified).sorted() == [], "classify these in ChatStore.accountState or .appState")
        #expect(classified.subtracting(names).sorted() == [], "these are no longer stored properties")
        #expect(ChatStore.accountState.isDisjoint(with: ChatStore.appState))
    }
    /// Home's thread rows come back with the cache, so a conversation shown as its thread doesn't flash up as a plain row first.
    @Test func homeThreadsComeBackWithTheCache() async throws {
        let cache = Self.cache()
        let first = ChatStore(backend: FakeBackend(), cache: cache)
        await first.start()
        #expect(!first.rooms.homeThreads.isEmpty)
        first.flush()
        let next = ChatStore(backend: FakeBackend(), cache: cache)
        #expect(next.rooms.homeThreads.map(\.id) == first.rooms.homeThreads.map(\.id))
    }
    /// Signing out on purpose drops what the cache holds of the account's chats (Google keeps it all) and the cached
    /// pictures and files, but not the drafts, which only this Mac has.
    @Test func signingOutForgetsHistoryButKeepsDrafts() async throws {
        let cache = Self.cache()
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        var cleared = false
        store.clearDiskCaches = { cleared = true }
        await store.start()
        let id = try #require(store.navigation.selectedID)
        store.setDraft("not sent yet", conversation: id, thread: nil)
        store.flush()
        #expect(!cache.load().messages.isEmpty)
        store.signedOut()
        let saved = cache.load()
        #expect(saved.messages.isEmpty && saved.conversations.isEmpty && saved.homeThreads.isEmpty)
        #expect(saved.drafts.values.contains("not sent yet"))
        #expect(cleared)
    }
    @Test func ownCacheSurvivesConnect() async throws {
        let cache = Self.cache()
        try cache.save(LaunchSnapshot(accountID: FakeBackend.me.id, drafts: ["engineering/timeline": "my draft"]))
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        await store.start()
        #expect(store.drafting.text["engineering/timeline"] == "my draft")
    }
    @Test func flushWritesTheCacheWithoutWaitingForTheDelay() async throws {
        let cache = Self.cache()
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        await store.start()
        let id = try #require(store.navigation.selectedID)
        store.setDraft("typed just before quitting", conversation: id, thread: nil)
        store.flush()
        #expect(cache.load().drafts.values.contains("typed just before quitting"))
    }
    /// Draft formatting this build can't read loses the formatting, never the drafts' text.
    @Test func unreadableDraftFormattingKeepsTheDrafts() throws {
        let cache = Self.cache()
        let json =
            #"{"accountID":"me","drafts":{"k":"kept"},"draftFormatting":{"k":[{"unexpected":true}]},"serverDrafts":{"k":7}}"#
        try Data(json.utf8).write(to: cache.url)
        #expect(cache.load().drafts["k"] == "kept")
    }
    /// A cache this build can't read at all is moved aside, not overwritten by the next save: its drafts can be recovered.
    @Test func anUnreadableCacheIsKeptAside() throws {
        let cache = Self.cache()
        try Data("not json".utf8).write(to: cache.url)
        #expect(cache.load().drafts.isEmpty)
        #expect(try Data(contentsOf: cache.url.appendingPathExtension("unreadable")) == Data("not json".utf8))
    }
    /// Quitting while a message is still sending (a slow upload) keeps it, as failed: Retry sends it after relaunch.
    @Test func aMessageBeingSentSurvivesAQuit() async throws {
        let cache = Self.cache()
        let store = ChatStore(backend: FakeBackend(latency: .milliseconds(400)), cache: cache)
        await store.start()
        let file = URL.temporaryDirectory.appending(path: "parley-upload-\(UUID().uuidString).txt")
        try Data("file".utf8).write(to: file)
        store.attach([file], conversation: "alex", thread: nil)
        store.setDraft("with a file", conversation: "alex", thread: nil)
        async let sending: Void = store.send(conversation: "alex")
        try await Task.sleep(for: .milliseconds(100))
        store.flush()
        #expect(cache.load().messages.first { $0.text == "with a file" }?.delivery == .failed)
        await sending
    }
    @Test func aChangedModelLosesHistoryButKeepsDrafts() throws {
        let cache = Self.cache()
        let json = #"{"accountID":"me","conversations":[{"unexpected":true}],"messages":[],"drafts":{"k":"kept"}}"#
        try Data(json.utf8).write(to: cache.url)
        let snapshot = cache.load()
        #expect(snapshot.conversations.isEmpty && snapshot.drafts["k"] == "kept")
    }
}

/// Reaching the top while the newest page is still reloading: the table asks once, and a reload of the same rows
/// gives it no reason to ask again, so the older page must follow the reload instead of being dropped.
@MainActor struct OlderPageDuringReloadTests {
    @Test func askingForOlderDuringAReloadStillPagesBack() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 200, latency: .milliseconds(200)))
        await store.start()
        await store.select("engineering")
        let before = store.timeline("engineering").count
        let reload = Task { await store.select("engineering") }  // reopening: the newest page reloads
        while !store.history.loading.contains(store.key("engineering", nil)) { await Task.yield() }
        await store.loadOlderIfNeeded("engineering")  // the table reached the top meanwhile
        await reload.value
        #expect(store.timeline("engineering").count > before)
    }
}
