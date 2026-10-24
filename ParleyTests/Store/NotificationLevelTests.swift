import Foundation
import SwiftProtobuf
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Which pushed messages notify at each per-conversation level, as web and mobile Chat decide.
struct NotificationLevelPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    enum Case: CaseIterable {
        case plain, newThread, followedReply, unfollowedReply, mentionMe, mentionAll, mine, muted
    }

    func notifies(_ level: NotificationLevel?, _ scenario: Case) -> Bool {
        var room = Conversation.fixture(
            scenario == .plain ? "dm/b" : "space/a", kind: scenario == .plain ? .direct : .space, name: "Room")
        room.notificationLevel = level
        room.muted = scenario == .muted
        let reply = [.followedReply, .unfollowedReply, .mentionMe, .mentionAll].contains(scenario)
        let mention: [TextStyleRange] =
            switch scenario {
            case .mentionMe, .muted: [TextStyleRange(style: .mention(userID: "me"), start: 0, length: 2)]
            case .mentionAll: [TextStyleRange(style: .mention(userID: TextStyleRange.everyone), start: 0, length: 2)]
            default: []
            }
        let message = Message.fixture(
            id: "m1", from: scenario == .mine ? .fixture("me", name: "Dave") : .fixture(), in: room.id,
            thread: reply ? "t1" : nil,
            at: now
        ) { $0.formatting = mention }
        return NotificationPolicy.notification(
            for: message, in: room, me: "me", openConversation: nil, openThread: nil, appActive: false,
            settings: .init(), threadFollowed: scenario == .followedReply, now: now) != nil
    }

    @Test(arguments: [
        // level: plain, new thread, followed reply, unfollowed reply, @me, @all, mine, muted (with @me)
        (NotificationLevel?.none, [true, true, true, true, true, true, false, false]),
        (.always, [true, true, true, true, true, true, false, false]),
        (.all, [true, true, true, true, true, true, false, false]),
        (.main, [true, true, true, false, true, true, false, false]),
        (.forYouAndNewThreads, [true, true, true, false, true, true, false, false]),
        (.forYou, [false, false, true, false, true, true, false, false]),
        (.off, [false, false, false, false, false, false, false, false]),
    ])
    func levelTable(_ level: NotificationLevel?, _ expected: [Bool]) {
        #expect(Case.allCases.map { notifies(level, $0) } == expected)
    }

    @Test func choicesMirrorTheWeb() {
        #expect(NotificationLevel.choices(for: .space, current: .main) == [.all, .main, .forYou, .off])
        #expect(NotificationLevel.choices(for: .direct, current: .off) == [.always, .off])
        #expect(NotificationLevel.choices(for: .group, current: nil) == [.always, .off])
        #expect(NotificationLevel.choices(for: .space, current: .always) == [.always, .main, .forYou, .off])  // an older space's "all"
        #expect(
            NotificationLevel.choices(for: .space, current: .forYouAndNewThreads) == [
                .all, .main, .forYou, .off, .forYouAndNewThreads,
            ])
        #expect(NotificationLevel.choices(for: .direct, current: .forYou) == [.always, .off, .forYou])
        #expect(
            NotificationLevel.all.title == "All new messages" && NotificationLevel.always.title == "All new messages")
        #expect(NotificationLevel.main.title == "Main conversations" && NotificationLevel.forYou.title == "For you")
        #expect(NotificationLevel.off.title == "Don't notify")
    }
}

/// The level, follow state and @all from the wire.
struct NotificationLevelMappingTests {
    func room(_ level: Dynamite_GroupNotificationSettings.Level?) -> Conversation? {
        DynamiteMapper.conversation(
            .with {
                $0.groupID.spaceID.spaceID = "s1"
                $0.roomName = "Design"
                if let level { $0.readState.notificationSettings.level = level }
            }, selfID: "me", people: [:])
    }
    @Test func levelComesFromTheSidebarRead() {
        #expect(room(nil)?.notificationLevel == nil)
        let pairs: [(Dynamite_GroupNotificationSettings.Level, NotificationLevel)] = [
            (.notifyAlways, .always), (.notifyLessWithNewThreads, .forYouAndNewThreads), (.notifyLess, .forYou),
            (.notifyNever, .off),
            (.notifyForMainConversationsWithAutofollow, .all), (.notifyForMainConversations, .main),
        ]
        for (wire, level) in pairs {
            #expect(room(wire)?.notificationLevel == level)
            #expect(DynamiteMapper.wire(level) == wire)
        }
    }
    @Test func aFollowedThreadsHeadIsMarked() {
        func topic(_ labels: [Dynamite_TopicLabelId.TypeEnum]) -> Dynamite_Topic {
            .with {
                $0.id.topicID = "t1"
                $0.replies = [
                    .with {
                        $0.id.parentID.topicID.topicID = "t1"
                        $0.id.messageID = "t1"
                        $0.creator.userID.id = "u1"
                        $0.textBody = "hi"
                    }
                ]
                $0.topicReadState.topicLabelID = labels.map { type in .with { $0.type = type } }
            }
        }
        #expect(
            DynamiteMapper.topic(topic([.threadFollowed]), in: "space/s1", selfID: "me", people: [:]).first?.following
                == true)
        #expect(
            DynamiteMapper.topic(topic([.threadUnread]), in: "space/s1", selfID: "me", people: [:]).first?.following
                == false)
    }
    @Test func mentionAllIsKeptAsEveryone() throws {
        let proto = Dynamite_Message.with {
            $0.id.parentID.topicID.topicID = "t1"
            $0.id.messageID = "t1"
            $0.creator.userID.id = "u1"
            $0.textBody = "@all hi"
            $0.annotations = [
                .with {
                    $0.type = .userMention
                    $0.startIndex = 0
                    $0.length = 4
                    $0.userMentionMetadata.type = .mentionAll
                }
            ]
        }
        let message = try #require(DynamiteMapper.message(proto, in: "space/s1", selfID: "me", people: [:]))
        #expect(message.formatting.first?.style == .mention(userID: TextStyleRange.everyone))
        let sent = DynamiteMapper.annotations(message.formatting)  // sent back as @all, never as a person
        #expect(
            sent.count == 1 && sent[0].userMentionMetadata.type == .mentionAll && !sent[0].userMentionMetadata.hasID)
    }
    @Test func launchCachesWithoutTheNewFieldsStillDecode() throws {
        let room = #"{"id":"s","name":"A","kind":"space","members":[],"unread":0,"pinned":false,"muted":false}"#
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(room.utf8)).notificationLevel == nil)
        let message = Message(id: "m", conversationID: "s", sender: Person(id: "u", name: "U"), text: "x")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        json["following"] = nil
        #expect(
            try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json)).following
                == false)
    }
}

/// update_group_notification_settings for a level change, and the pushed changes; network-stubbed.
extension NetworkTests { @Suite struct NotificationLevelTests: NetworkSuite {} }

extension NetworkTests.NotificationLevelTests {
    /// GroupId {space_id(1) {space_id(1) "s1"}}.
    private static let levelSpace = Data([0x0A, 0x04, 0x0A, 0x02, 0x73, 0x31])
    private static func notificationBodies(_ exchange: StubExchange) -> [Data] {
        exchange.requests.filter { $0.url?.path == "/api/update_group_notification_settings" }.map(Self.body)
    }

    /// {group_id(1), settings(2) {level(2), mute_settings(3) {state(1)}}}: the new level with the mute state as it is;
    /// a later mute resends the new level.
    @Test func levelChangeSendsTheLevelAndKeepsMute() async throws {
        let done = try Self.proto(Dynamite_UpdateGroupNotificationSettingsResponse())
        let (backend, exchange) = try await Self.connected([done, done, done])
        try await backend.setNotificationLevel(.forYou, muted: true, for: "space/s1")
        try await backend.setNotificationLevel(.all, muted: false, for: "space/s1")
        try await backend.setMuted(true, for: "space/s1")
        let bodies = Self.notificationBodies(exchange)
        #expect(bodies.count == 3)
        #expect(
            bodies[0].starts(
                with: Data([0x0A, 0x06]) + Self.levelSpace + Data([0x12, 0x06, 0x10, 0x02, 0x1A, 0x02, 0x08, 0x02])))
        #expect(
            bodies[1].starts(
                with: Data([0x0A, 0x06]) + Self.levelSpace + Data([0x12, 0x06, 0x10, 0x04, 0x1A, 0x02, 0x08, 0x01])))
        #expect(
            bodies[2].starts(
                with: Data([0x0A, 0x06]) + Self.levelSpace + Data([0x12, 0x06, 0x10, 0x04, 0x1A, 0x02, 0x08, 0x02])))
        #expect(try Dynamite_UpdateGroupNotificationSettingsRequest(serializedBytes: bodies[0]).hasRequestHeader)
    }

    static func labelPushed(
        _ type: Dynamite_EventBody.EventType, topic: String, label: Dynamite_TopicLabelId.TypeEnum = .threadFollowed
    ) -> Dynamite_StreamEventsResponse {
        .with {
            $0.event.groupID.spaceID.spaceID = "x"
            $0.event.bodies = [
                .with {
                    $0.eventType = type
                    $0.topicLabel.topicID.topicID = topic
                    $0.topicLabel.label.type = label
                }
            ]
        }
    }
    @Test func pushedFollowLabelsBecomeFollowChanges() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.labelPushed(.topicLabelApplied, topic: "t1"))
        await backend.handle(Self.labelPushed(.topicLabelRemoved, topic: "t2"))
        await backend.handle(Self.labelPushed(.topicLabelApplied, topic: "t3", label: .threadUnread))  // not a follow
        let changes = await Self.drain(backend).compactMap { event -> String? in
            if case .threadFollowChanged(let thread, let following) = event { "\(thread) \(following)" } else { nil }
        }
        #expect(changes == ["space/x/t1/t1 true", "space/x/t2/t2 false"])
    }
    @Test func pushedSettingsChangeRereadsTheConversation() async throws {
        let world = try Self.proto(
            Dynamite_PaginatedWorldResponse.with {
                $0.worldItems = [
                    .with {
                        $0.groupID.spaceID.spaceID = "s1"
                        $0.roomName = "Design"
                        $0.readState.notificationSettings.level = .notifyForMainConversations
                    }
                ]
            })
        let (backend, _) = try await Self.connected([world])
        await backend.handle(
            .with {
                $0.event.bodies = [
                    .with {
                        $0.eventType = .groupNotificationSettingsUpdated
                        $0.groupNotificationSettingsUpdated.groupID.spaceID.spaceID = "s1"
                    }
                ]
            })
        #expect(NetworkTests.LiveChangesTests.rooms(await Self.drain(backend)).map(\.notificationLevel) == [.main])
    }
    /// A reply pushed for a thread never loaded here is still a reply (the server marks heads), so it is not a new thread.
    @Test func aPushedReplyToAnUnloadedThreadIsAReply() async throws {
        let (backend, _) = try await Self.connected()
        var head = Dynamite_StreamEventsResponse.with { $0.event.groupID.spaceID.spaceID = "x" }
        head.event.bodies = [
            .with {
                $0.eventType = .messagePosted
                $0.messagePosted.message = Self.message("t5", topic: "t5", at: 1)
                $0.messagePosted.isHead = true
            }
        ]
        var reply = Dynamite_StreamEventsResponse.with { $0.event.groupID.spaceID.spaceID = "x" }
        reply.event.bodies = [
            .with {
                $0.eventType = .messagePosted
                $0.messagePosted.message = Self.message("r9", topic: "t9", at: 2)
                $0.messagePosted.isHead = false
            }
        ]
        await backend.handle(head)
        await backend.handle(reply)
        let messages = Self.upserts(await Self.drain(backend))
        #expect(messages.map(\.id) == ["space/x/t5/t5", "space/x/t9/r9"])
        #expect(messages.map(\.threadID) == [nil, "space/x/t9/t9"])
    }
}

/// The store: picking a level, and knowing which threads I follow.
@MainActor
struct NotificationLevelStoreTests {
    func started(latency: Duration = .zero) async -> (ChatStore, RecordingNotifier, FakeBackend) {
        let fake = FakeBackend(latency: latency)
        let notifier = RecordingNotifier()
        let store = ChatStore(backend: fake)
        store.notifier = notifier
        store.notificationSettings = { NotificationSettings() }
        store.isAppActive = { false }
        await store.start()
        return (store, notifier, fake)
    }
    func level(_ store: ChatStore, _ id: ConversationID) -> NotificationLevel? {
        store.rooms.conversations.first { $0.id == id }?.notificationLevel
    }

    @Test func pickingALevelShowsAtOnceAndSendsTheMuteState() async throws {
        let (store, _, fake) = await started(latency: .milliseconds(400))
        let pending = Task { await store.setNotificationLevel(.forYou, "engineering") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(level(store, "engineering") == .forYou)
        await pending.value
        #expect(await fake.changes == ["level forYou muted engineering"])
        try await store.refresh()
        #expect(level(store, "engineering") == .forYou)
    }
    @Test func aRefusedLevelRollsBackAndSaysWhy() async {
        let (store, _, fake) = await started()
        await fake.simulateChangeFailure()
        await store.setNotificationLevel(.off, "design")
        #expect(level(store, "design") == nil && store.toast != nil)  // put back, with a note
    }
    @Test func repliesNotifyAtForYouOnlyInThreadsIFollow() async {
        let (store, notifier, _) = await started()
        await store.setNotificationLevel(.forYou, "general")
        func push(_ id: String, thread: ThreadID?, from sender: Person = .fixture(), following: Bool = false) {
            store.apply(
                .messageUpserted(
                    .fixture(id, id: MessageID(id), from: sender, in: "general", thread: thread, at: .now) {
                        $0.following = following
                    }))
        }
        push("h1", thread: nil)  // a new thread: not for me
        push("r1", thread: "h1")  // a reply in a thread I don't follow
        push("mine", thread: "h1", from: FakeBackend.me)  // I reply: now I follow it
        push("r2", thread: "h1")
        push("h2", thread: nil, following: true)  // loaded as followed
        push("r3", thread: "h2")
        store.apply(.threadFollowChanged("h2", following: false))  // unfollowed elsewhere
        push("r4", thread: "h2")
        store.apply(.threadFollowChanged("h3", following: true))
        push("r5", thread: "h3")
        #expect(notifier.posted.map(\.id) == ["r2", "r3", "r5"])
    }
    private func followedThread(_ id: String, in conversation: ConversationID) -> HomeThread {
        let head = Message.fixture(
            "head", id: MessageID(id), from: .fixture("alex", name: "Alex Rivera"), in: conversation, at: .now)
        return HomeThread(
            id: ThreadID(id), conversationID: conversation, head: head, latest: head, unread: false,
            time: head.createdAt)
    }
    /// Home's threads are the server's followed threads: a reply in one notifies at "For you" without the thread loaded.
    @Test func homeThreadsCountAsFollowed() async throws {
        let (store, notifier, fake) = await started()
        await store.setNotificationLevel(.forYou, "general")
        await fake.setHomeThreads([followedThread("x1", in: "general")])
        try await store.refresh()
        store.apply(.messageUpserted(.fixture("r1", id: "r1", in: "general", thread: "x1", at: .now)))
        #expect(notifier.posted.map(\.id) == ["r1"])
    }
    /// A reply in a thread Parley doesn't know yet: the server's followed threads say whether it notifies, and Home shows it.
    @Test func aReplyInAnUnknownThreadAsksTheServerWhetherItIsFollowed() async throws {
        let (store, notifier, fake) = await started()
        await store.setNotificationLevel(.forYou, "general")
        await fake.setHomeThreads([followedThread("x2", in: "general")])  // the server already lists it; Parley hasn't refreshed
        store.apply(.messageUpserted(.fixture("r2", id: "r2", in: "general", thread: "x2", at: .now)))
        store.apply(.messageUpserted(.fixture("r3", id: "r3", in: "general", thread: "x3", at: .now)))  // not followed
        await eventually { notifier.posted.contains(where: { $0.id == "r2" }) }
        #expect(notifier.posted.map(\.id) == ["r2"])
        #expect(store.rooms.homeThreads.contains { $0.id == "x2" })
    }
    /// Home lists a followed thread as soon as a reply arrives in it, even where every message notifies anyway.
    @Test func aReplyInAThreadMissingFromHomeShowsThereSoon() async throws {
        let (store, notifier, fake) = await started()
        await fake.setHomeThreads([followedThread("x4", in: "general")])
        store.apply(.messageUpserted(.fixture("r4", id: "r4", in: "general", thread: "x4", at: .now)))
        await eventually { store.rooms.homeThreads.contains(where: { $0.id == "x4" }) }
        #expect(store.rooms.homeThreads.contains { $0.id == "x4" })
        #expect(notifier.posted.map(\.id) == ["r4"])  // once: it notified when it arrived
    }
    /// On Home the last-opened conversation is still selected (Home's thread pane opens in it), but its timeline is off
    /// screen: a new message there stays unread and notifies, as in any other conversation.
    @Test func homeLeavesTheLastConversationUnread() async throws {
        let (store, notifier, _) = await started()
        store.isAppActive = { true }
        await store.select("general")
        await store.openShortcut(.home)
        #expect(store.navigation.selectedID == "general")
        store.apply(.messageUpserted(.fixture("new on Home", id: "h1", in: "general", at: .now)))
        #expect(notifier.posted.map(\.id) == ["h1"])
        var room = try #require(store.rooms.conversations.first { $0.id == "general" })
        room.unread = 1
        store.apply(.conversationUpserted(room))
        #expect(store.rooms.conversations.first { $0.id == "general" }?.unread == 1)
    }
    /// Home's re-read only takes the server's followed threads: it leaves the conversation list as Parley has it, with
    /// changes the server hasn't sent back yet (here a badge counted from a pushed message).
    @Test func homesReReadLeavesTheConversationListAlone() async throws {
        let (store, _, fake) = await started()
        store.followRecheck = .milliseconds(50)
        await fake.setHomeThreads([followedThread("x8", in: "general")])
        let before = try #require(store.rooms.conversations.first { $0.id == "engineering" }).unread
        store.apply(.messageUpserted(.fixture("new", id: "e1", in: "engineering", at: .now)))
        #expect(store.rooms.conversations.first { $0.id == "engineering" }?.unread == before + 1)
        store.apply(.messageUpserted(.fixture("r8", id: "r8", in: "general", thread: "x8", at: .now)))
        await eventually { store.rooms.homeThreads.contains(where: { $0.id == "x8" }) }
        try await Task.sleep(for: .milliseconds(150))  // the second read too
        #expect(store.rooms.homeThreads.contains { $0.id == "x8" })
        #expect(store.rooms.conversations.first { $0.id == "engineering" }?.unread == before + 1)
    }
    /// A burst of pushed messages in the open conversation (a reconnect's catch-up) marks it read once or twice, not once
    /// per message.
    @Test func aBurstInTheOpenConversationMarksItReadOnce() async throws {
        let (store, _, fake) = await started()
        store.isAppActive = { true }
        await store.select("general")
        let before = await fake.markedRead.count
        for index in 0..<50 {
            store.apply(.messageUpserted(.fixture("\(index)", id: "b\(index)", in: "general", at: .now)))
        }
        try await Task.sleep(for: .milliseconds(200))
        let reads = await fake.markedRead.count - before
        #expect((1...2).contains(reads), "\(reads) read calls")
    }
    /// A burst of resyncs (a flapping connection) is one refresh, not several at once that finish out of order.
    @Test func resyncsDoNotPileUp() async throws {
        let (store, _, fake) = await started()
        let start = await fake.listReads
        for _ in 0..<5 { store.apply(.resync) }
        try await Task.sleep(for: .milliseconds(300))
        let reads = await fake.listReads - start
        #expect(reads == 1, "\(reads) list reads")
    }
    /// Google lists a reply's thread a moment after pushing the reply: a read right away misses it, the one after finds it.
    @Test func aThreadTheServerListsLateStillReachesHome() async throws {
        let (store, notifier, fake) = await started()
        store.followRecheck = .milliseconds(300)
        await fake.setHomeThreads([])
        await store.setNotificationLevel(.forYou, "general")
        store.apply(.messageUpserted(.fixture("r6", id: "r6", in: "general", thread: "x6", at: .now)))
        store.apply(.messageUpserted(.fixture("r7", id: "r7", in: "engineering", thread: "x7", at: .now)))  // a burst
        try await Task.sleep(for: .milliseconds(100))  // the first read is done and found neither
        await fake.setHomeThreads([followedThread("x6", in: "general"), followedThread("x7", in: "engineering")])
        await eventually { store.rooms.homeThreads.count >= 2 }
        #expect(Set(store.rooms.homeThreads.map(\.id)) == ["x6", "x7"])
        #expect(notifier.posted.map(\.id).contains("r6"))  // its banner waited for the read that found it
    }
}
