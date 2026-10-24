import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// A space's Threads list, as Google Chat's Active threads: the threads with replies, newest reply first, filtered here.
extension NetworkTests { @Suite struct ThreadsListBackendTests: NetworkSuite {} }

extension NetworkTests.ThreadsListBackendTests {
    @Test func theThreadsListIsTheSummaryListTopicsThenItIsMarkedSeen() async throws {
        func topic(_ id: String, at sort: Int64, replies: Int64, unread: Int64, mention: Bool, followed: Bool)
            -> Dynamite_Topic
        {
            var head = Self.message(id, topic: id, at: sort - 100)
            head.id.parentID.topicID.groupID.spaceID.spaceID = "s9"
            var reply = Self.message("\(id)r", topic: id, at: sort)
            reply.id.parentID.topicID.groupID.spaceID.spaceID = "s9"
            return .with { built in
                built.id.topicID = id
                built.id.groupID.spaceID.spaceID = "s9"
                built.sortTime = sort
                built.replies = [head, reply]
                built.topicReadState.replySummary = .with {
                    $0.totalReplyCount = replies
                    $0.unreadReplyCount = unread
                    $0.unreadAttributes = mention ? [.userMentioned] : []
                }
                if followed { built.topicReadState.topicLabelID = [.with { $0.type = .threadFollowed }] }
            }
        }
        let listed = Dynamite_ListTopicsResponse.with {
            $0.topics = [
                topic("t1", at: 2_000_000, replies: 3, unread: 1, mention: true, followed: true),
                topic("t2", at: 1_000_000, replies: 1, unread: 0, mention: false, followed: false),
            ]
        }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(listed), try Self.proto(Dynamite_MarkGroupReadstateResponse()),
        ])
        let threads = try await backend.threads(in: "space/s9")
        let sent = try Dynamite_ListTopicsRequest(
            serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/list_topics" })))
        #expect(sent.filter.threadSummary && sent.field11 == 1 && sent.pageSizeForTopics == 40)
        #expect(threads.map(\.head.id) == ["space/s9/t1/t1", "space/s9/t2/t2"])
        #expect(
            threads[0].replyCount == 3 && threads[0].unreadCount == 1 && threads[0].mentionsMe && threads[0].following)
        #expect(
            !threads[1].following && threads[1].unreadCount == 0
                && threads[1].lastReply == Date(timeIntervalSince1970: 1))
        let seen = try Dynamite_MarkGroupReadstateRequest(
            serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(
            exchange.requests.last?.url?.path == "/api/mark_group_readstate" && seen.threadSummaryReadTime == 2_000_000
                && !seen.hasLastReadTime)
    }
}

@MainActor struct ThreadsListTests {
    private func thread(_ id: String, unread: Int = 0, mentions: Bool = false, following: Bool = false) -> ThreadSummary
    {
        ThreadSummary(
            head: .fixture(id, id: MessageID(id), in: "s"), replyCount: 2,
            unreadCount: unread, mentionsMe: mentions, following: following, lastReply: .now)
    }
    @Test func filtersCombine() {
        let all = [
            thread("a", unread: 2, following: true), thread("b", unread: 1, mentions: true),
            thread("c", following: true),
        ]
        #expect(ThreadSummary.filtered(all, by: []).map(\.id) == ["a", "b", "c"])
        #expect(ThreadSummary.filtered(all, by: [.following]).map(\.id) == ["a", "c"])
        #expect(ThreadSummary.filtered(all, by: [.following, .unread]).map(\.id) == ["a"])
        #expect(ThreadSummary.filtered(all, by: [.mentions]).map(\.id) == ["b"])
    }
    @Test func theListOpensInThePaneAndAThreadOpensFromIt() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        store.navigation.setPane(nil) { $0.content = .info }
        await store.showThreads(true)
        #expect(store.navigation.pane(nil).threads && !store.navigation.pane(nil).info)
        let first = try #require(store.history.threadSummaries["design"]?.first)
        #expect(first.head.id == "d4" && first.replyCount == 2)
        await store.openThread(first.head)
        #expect(
            store.navigation.threadID == "d4" && store.navigation.pane(nil).threads,
            "closing the thread goes back to the list")
    }
    /// The Threads button shows the list when it isn't on screen (a thread open over it, or the info panel), and
    /// closes it when it is: one click either way.
    @Test func theThreadsButtonFollowsWhatIsOnScreen() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        await store.toggleThreads()
        #expect(store.navigation.pane(nil).threads && store.navigation.threadID == nil)
        await store.openThread(try #require(store.history.threadSummaries["design"]?.first).head)
        await store.toggleThreads()  // a thread is open over the list: back to the list
        #expect(store.navigation.pane(nil).threads && store.navigation.threadID == nil)
        await store.toggleThreads()
        #expect(!store.navigation.pane(nil).threads)
        store.toggleInfo()
        await store.toggleThreads()  // the info panel was showing: the list replaces it
        #expect(store.navigation.pane(nil).threads && !store.navigation.pane(nil).info)
    }
    /// A conversation window has a side pane of its own: what opens there leaves the main window's pane as it was, even
    /// with the same conversation in both.
    @Test func aConversationWindowHasItsOwnPane() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        await store.showThreads(true, window: "design")
        let head = try #require(store.history.threadSummaries["design"]?.first).head
        await store.openThread(head, window: "design")
        #expect(store.navigation.pane("design") == SidePane(content: .thread("d4"), threads: true))
        #expect(
            store.navigation.pane(nil) == SidePane() && store.navigation.threadID == nil,
            "the main window's pane stays closed")
        store.toggleInfo(window: "design")
        #expect(store.navigation.pane("design").info && !store.navigation.pane(nil).info)
        store.toggleInfo()
        #expect(
            store.navigation.pane(nil).info && store.navigation.pane("design").info,
            "and the main window's info opens on its own")
    }
    /// With nothing to list, the header and filters stay at the top of the pane; they used to sink to its middle.
    @Test func theHeaderStaysAtTheTopWhenNothingMatches() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.rooms.conversations.first { $0.id == "design" })
        await store.loadThreads(room.id)
        let saved = UserDefaults.standard.string(forKey: "threadsFilters")
        UserDefaults.standard.set("Mentions", forKey: "threadsFilters")  // as in the report: a filter nothing matches
        defer { UserDefaults.standard.set(saved, forKey: "threadsFilters") }
        let height: CGFloat = 700
        // Placed as SidePaneSplit places it: a width, and the timeline beside it setting the height.
        let host = NSHostingView(
            rootView: HStack(spacing: 0) {
                Color.clear.frame(width: 1, height: height)
                ThreadsPane(room: room).environment(store).frame(width: ChatView.paneWidth - 1)
            })
        host.frame = NSRect(x: 0, y: 0, width: ChatView.paneWidth, height: height)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        /// Dark pixels (the "Threads" title) in the top 70 pt.
        func inked() -> Int {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
            host.cacheDisplay(in: host.bounds, to: rep)
            var count = 0
            for y in 0..<Int(70 * rep.size.height / height * CGFloat(rep.pixelsHigh) / rep.size.height) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5, color.brightnessComponent < 0.4
                    {
                        count += 1
                    }
                }
            }
            return count
        }
        await eventually { inked() > 20 }
    }
    /// Google Chat's DMs and group DMs have threads too; a DM with an app doesn't.
    @Test func threadsAreOfferedWhereverThreadsExist() {
        #expect(ChatView.offersThreads(Conversation.fixture("s", name: "S")))
        #expect(ChatView.offersThreads(Conversation.fixture("d", kind: .direct, name: "D")))
        #expect(ChatView.offersThreads(Conversation.fixture("g", kind: .group, name: "G")))
        #expect(!ChatView.offersThreads(Conversation.fixture("a", kind: .direct, name: "A", app: .bot)))
    }
}
