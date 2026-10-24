import Foundation
import SwiftProtobuf
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

extension NetworkTests { @Suite struct DynamiteBackendTests: NetworkSuite {} }

extension NetworkTests.DynamiteBackendTests {
    @Test func clientPostsBinaryProtoWithRtB() async throws {
        let response = Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me-id" }
        let (auth, exchange) = try Self.signedIn([try Self.proto(response)])
        let client = DynamiteClient(authorizer: auth)
        let decoded: Dynamite_GetSelfUserStatusResponse = try await client.call(
            "get_self_user_status", Dynamite_GetSelfUserStatusRequest.with { $0.requestHeader = DynamiteClient.header })
        #expect(decoded.userStatus.userID.id == "me-id")
        let rpc = try #require(exchange.requests.last)
        #expect(rpc.url?.absoluteString == "https://chat.google.com/api/get_self_user_status?rt=b")
        #expect(rpc.httpMethod == "POST")
        #expect(rpc.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
    }
    /// URLSession can hand a request to a keep-alive connection the server already closed: one retry, as on a fresh one.
    @Test func clientRetriesOnceWhenTheConnectionWasLost() async throws {
        let response = Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me-id" }
        let (auth, exchange) = try Self.signedIn([.init(failure: .networkConnectionLost), try Self.proto(response)])
        let decoded: Dynamite_GetSelfUserStatusResponse = try await DynamiteClient(authorizer: auth).call(
            "get_self_user_status", Dynamite_GetSelfUserStatusRequest())
        #expect(decoded.userStatus.userID.id == "me-id")
        #expect(exchange.requests.filter { $0.url?.path == "/api/get_self_user_status" }.count == 2)
        let (twice, _) = try Self.signedIn([
            .init(failure: .networkConnectionLost), .init(failure: .networkConnectionLost),
        ])
        await #expect(throws: URLError.self) {
            let _: Dynamite_GetSelfUserStatusResponse = try await DynamiteClient(authorizer: twice).call(
                "get_self_user_status", Dynamite_GetSelfUserStatusRequest())
        }
    }
    /// A call that makes something new each time (a Meet link, a group, a report) isn't repeated: if the lost connection
    /// had already delivered it, a retry would make a second one. The error shows instead.
    @Test func callsThatCreateAreNotRetried() async throws {
        let (auth, exchange) = try Self.signedIn([.init(failure: .networkConnectionLost), .init(data: Data())])
        await #expect(throws: URLError.self) {
            let _: Dynamite_CreateVideoCallResponse = try await DynamiteClient(authorizer: auth).call(
                "create_video_call", Dynamite_CreateVideoCallRequest())
        }
        #expect(exchange.requests.filter { $0.url?.path == "/api/create_video_call" }.count == 1)
    }
    /// A reply Parley can't read is not a sign-in problem, and reads as it always has.
    @Test func clientMapsUndecodableBodyToMalformedReply() async throws {
        let garbage = StubExchange.Reply(
            headers: ["Content-Type": "application/x-protobuf"], data: Data([0xFF, 0xFF, 0xFF]))
        let (auth, _) = try Self.signedIn([garbage])
        await #expect(throws: DynamiteError.malformedReply) {
            let _: Dynamite_GetSelfUserStatusResponse = try await DynamiteClient(authorizer: auth).call(
                "get_self_user_status", Dynamite_GetSelfUserStatusRequest())
        }
        #expect(
            await ChatStore.plain(DynamiteError.malformedReply)
                == "Google’s response did not match the expected protobuf schema.")
    }
}

extension NetworkTests.DynamiteBackendTests {
    private static func selfReply(_ id: String = "me") throws -> StubExchange.Reply {
        try proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = id })
    }
    private static func members(_ pairs: [(String, String)]) throws -> StubExchange.Reply {
        try proto(
            Dynamite_GetMembersResponse.with {
                $0.memberProfiles = pairs.map { id, name in
                    .with {
                        $0.member.user.userID.id = id
                        $0.member.user.name = name
                    }
                }
            })
    }
    private static func item(dm id: String, members: [String], sort: Int64, unread: Int64 = 0) -> Dynamite_WorldItemLite
    {
        .with {
            $0.groupID.dmID.dmID = id
            $0.sortTimestamp = sort
            $0.readState.unreadMessageCount = unread
            $0.dmMembers.members = members.map { member in .with { $0.id = member } }
        }
    }

    @Test func connectReturnsSignedInPerson() async throws {
        let (auth, _) = try Self.signedIn([try Self.selfReply(), try Self.members([("me", "Dave")])])
        let me = try await DynamiteBackend(authorizer: auth, realtime: false).connect()
        #expect(me == Person(id: "me", name: "Dave"))
    }
    /// Raw bytes pin the wire layout: request `membership_ids = 2`
    /// {member_id(1){user_id(1)}}, response `member_profiles = 2` {member(2){user(1)}}; field 1 is absent in this build.
    @Test func getMembersUsesFieldTwo() async throws {
        let user: [UInt8] = [0x0A, 0x04, 0x0A, 0x02, 0x6D, 0x65, 0x12, 0x04, 0x44, 0x61, 0x76, 0x65]  // User{user_id{"me"}, name "Dave"}
        let response = Data([0x12, 0x10, 0x12, 0x0E, 0x0A, 0x0C] + user)
        let (auth, exchange) = try Self.signedIn([
            try Self.selfReply(), .init(headers: ["Content-Type": "application/x-protobuf"], data: response),
        ])
        let me = try await DynamiteBackend(authorizer: auth, realtime: false).connect()
        #expect(me == Person(id: "me", name: "Dave"))
        let request = try #require(exchange.requests.last)
        #expect(Self.body(request).prefix(10) == Data([0x12, 0x08, 0x0A, 0x06, 0x0A, 0x04, 0x0A, 0x02, 0x6D, 0x65]))
    }
    @Test func connectReportsSignedOutWhenNoSession() async throws {
        let auth = WebSessionAuthorizer(vault: MemoryVault(), session: AuthStubProtocol.session(StubExchange([])))
        await #expect(throws: AuthFailure.signInRequired) {
            _ = try await DynamiteBackend(authorizer: auth, realtime: false).connect()
        }
    }
    @Test func conversationsPaginateDedupeSortAndName() async throws {
        let first = Dynamite_PaginatedWorldResponse.with {
            $0.worldSectionResponses = [
                .with {
                    $0.worldItems = [Self.item(dm: "a", members: ["me", "u1"], sort: 1, unread: 2)]
                    $0.moreItems = true
                    $0.paginationToken = "next"
                }
            ]
        }
        let second = Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [
                Self.item(dm: "b", members: ["me", "u2"], sort: 9), Self.item(dm: "a", members: ["me", "u1"], sort: 1),
            ]
        }
        let (auth, exchange) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]),
            try Self.proto(first), try Self.proto(second),
            try Self.members([("u1", "Maria"), ("u2", "Alex")]),
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let rooms = try await backend.conversations()
        #expect(rooms.map(\.id) == ["dm/b", "dm/a"])  // newest first, deduplicated
        #expect(rooms.map(\.name) == ["Alex", "Maria"])
        #expect(rooms[1].unread == 2)
        #expect(
            exchange.requests.map { $0.url!.path } == [
                "/mole/world", "/api/get_self_user_status", "/api/get_members", "/api/paginated_world",
                "/api/paginated_world", "/api/get_members",
            ])
        // Checked live: only as the web client does Google include a group DM's name and GROUP_DM attribute.
        let worlds = try exchange.requests.filter { $0.url?.path == "/api/paginated_world" }
            .map { try Dynamite_PaginatedWorldRequest(serializedBytes: Self.body($0)) }
        #expect(!worlds.isEmpty && worlds.allSatisfy { $0.requestHeader.clientType == .web })
    }
    @Test func memberLookupFailureStillListsConversations() async throws {
        let world = Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [Self.item(dm: "a", members: ["me", "u1"], sort: 1)]
        }
        let (auth, _) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]),
            try Self.proto(world), .init(status: 500),
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        #expect(try await backend.conversations().map(\.name) == ["Unknown"])
    }
    @Test func repeatedWorldCursorFails() async throws {
        let looping = Dynamite_PaginatedWorldResponse.with {
            $0.worldSectionResponses = [
                .with {
                    $0.moreItems = true
                    $0.paginationToken = "same"
                }
            ]
        }
        let (auth, _) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(looping), try Self.proto(looping),
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        await #expect(throws: DynamiteError.malformedReply) { _ = try await backend.conversations() }
    }
    @Test func historyReturnsHeadsAndThreadsServeReplies() async throws {
        let topics = Dynamite_ListTopicsResponse.with {
            $0.topics = [
                .with {
                    $0.replies = [Self.message("h1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)]
                },
                .with { $0.replies = [Self.message("h2", topic: "t2", at: 3)] },
            ]
        }
        let (auth, _) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(topics),
            try Self.members([("u1", "Maria")]),
            try Self.proto(
                Dynamite_ListMessagesResponse.with {
                    $0.messages = [Self.message("h1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)]
                    $0.containsFirstMessage = true
                }),
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let page = try await backend.messages(in: "space/x", thread: nil, before: nil)
        #expect(page.messages.map(\.id) == ["space/x/t1/h1", "space/x/t2/h2"])
        #expect(page.messages[0].replyCount == 1 && page.hasMore)  // fixture has no contains_first_topic
        let thread = try await backend.messages(in: "space/x", thread: "space/x/t1/h1", before: nil)
        #expect(thread.messages.map(\.id) == ["space/x/t1/r1"])
        #expect(try await backend.messages(in: "space/x", thread: nil, before: .now).messages.isEmpty)
    }
    @Test func sendNewTopicReturnsServerMessage() async throws {
        let created = Dynamite_CreateTopicResponse.with {
            $0.topic.replies = [Self.message("m9", topic: "t9", at: 5, by: "me")]
        }
        let (auth, exchange) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(created),
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let sent = try await backend.send(MessageDraft(text: "m9", localID: "local-1"), to: "dm/a", thread: nil)
        #expect(sent.id == "dm/a/t9/m9" && sent.sender.name == "Dave" && sent.threadID == nil)
        #expect(exchange.requests.last?.url?.path == "/api/create_topic")
    }
    @Test func replyGoesToCreateMessageInThread() async throws {
        let created = Dynamite_CreateMessageResponse.with {
            $0.message = Self.message("r5", topic: "t1", at: 6, by: "me")
        }
        let (auth, exchange) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(created),
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let sent = try await backend.send(
            MessageDraft(text: "r5", localID: "local-2"), to: "space/x", thread: "space/x/t1/h1")
        #expect(sent.threadID == "space/x/t1/h1")
        #expect(exchange.requests.last?.url?.path == "/api/create_message")
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func sessionExpiringMidUseReportsSignedOut() async throws {
        let me = try Self.proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me" })
        let (auth, _) = try Self.signedIn([me, .init(status: 500), .init(status: 401), Self.xsrfReply, Self.signInPage])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        await #expect(throws: AuthFailure.signInRequired) { try await backend.markRead("dm/a") }
        await backend.disconnect()  // .offline marks the end of what to read
        var states: [ConnectionState] = []
        for await event in backend.events {
            guard case .connectionChanged(let state) = event else { continue }
            states.append(state)
            if state == .offline { break }
        }
        #expect(states == [.connecting, .signedOut, .offline])
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func pushedMessagesBecomeHeadsAndReplies() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        await backend.handle(Self.pushed(.messagePosted, Self.message("r1", topic: "t1", at: 2)))
        await backend.handle(Self.pushed(.messageUpdated, Self.message("r1", topic: "t1", at: 2)))  // edit: no second bump
        let messages = Self.upserts(await Self.drain(backend))
        #expect(messages.map(\.id) == ["space/x/t1/h1", "space/x/t1/r1", "space/x/t1/h1", "space/x/t1/r1"])
        #expect(messages[0].sender.name == "Maria" && messages[0].threadID == nil)
        #expect(messages[1].threadID == "space/x/t1/h1")
        #expect(messages[2].replyCount == 1)
    }
    @Test func pushedDeletesAndTombstonesRemoveMessages() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(
            .with {
                $0.event.groupID.dmID.dmID = "a"
                $0.event.bodies = [
                    .with {
                        $0.eventType = .messageDeleted
                        $0.messageDeleted.messageID.parentID.topicID.topicID = "t1"
                        $0.messageDeleted.messageID.messageID = "m1"
                    }
                ]
            })
        var tombstone = Self.message("m2", topic: "t2", at: 1)
        tombstone.deleteTime = 5
        await backend.handle(Self.pushed(.messageUpdated, tombstone))
        let deleted = await Self.drain(backend).compactMap { if case .messageDeleted(let id) = $0 { id } else { nil } }
        #expect(deleted == ["dm/a/t1/m1", "space/x/t2/m2"])
    }
    @Test func sessionReadyConnectsAndLaterReadyCatchesUp() async throws {
        let caughtUp = Dynamite_CatchUpResponse.with {
            $0.status = .completed
            $0.events = [
                .with {
                    $0.groupID.dmID.dmID = "a"
                    $0.bodies = [
                        .with {
                            $0.eventType = .messagePosted
                            $0.messagePosted.message = Self.message("m7", topic: "t7", at: 9)
                        }
                    ]
                }
            ]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(caughtUp)])
        await backend.handle(Self.ready)
        await backend.handle(.with { $0.event.userRevision.timestamp = 100 })
        await backend.handle(Self.ready)
        let events = await Self.drain(backend)
        #expect(events.filter { $0 == .connectionChanged(.connected) }.count == 2)
        #expect(Self.upserts(events).map(\.id) == ["dm/a/t7/m7"])
        #expect(exchange.requests.last?.url?.path == "/api/catch_up_user")
        #expect(!events.contains(.resync))
    }
    /// While the realtime channel is down, polling catch_up_user brings the events in as if pushed, from the
    /// revision already seen; one at that revision (a replay) is skipped so a reaction toggle never applies twice.
    /// Polling doesn't count as connected: catch_up_user leaves out new messages, so the status stays Reconnecting.
    @Test func pollingBringsNewEventsInOnce() async throws {
        func posted(_ id: String, at revision: Int64) -> Dynamite_Event {
            .with {
                $0.userRevision.timestamp = revision
                $0.groupID.dmID.dmID = "a"
                $0.bodies = [
                    .with {
                        $0.eventType = .messagePosted
                        $0.messagePosted.message = Self.message(id, topic: id, at: 9)
                    }
                ]
            }
        }
        let polled = Dynamite_CatchUpResponse.with {
            $0.status = .completed
            $0.events = [posted("m1", at: 100), posted("m2", at: 200)]
        }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(polled), try Self.members([("u1", "Maria")]), .init(status: 500),
        ])
        await backend.handle(.with { $0.event.userRevision.timestamp = 100 })
        #expect(await backend.poll())
        let events = await Self.drain(backend)
        #expect(Self.upserts(events).map(\.id) == ["dm/a/m2/m2"])
        #expect(!events.contains(.connectionChanged(.connected)) && !events.contains(.resync))
        let sent = try Dynamite_CatchUpUserRequest(
            serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/catch_up_user" })))
        #expect(sent.range.fromRevisionTimestamp == 100)
        #expect(!(await backend.poll()))  // a failed round changes nothing and asks for no resync
    }
    /// The fallback poll runs only while the channel is down: it starts when the channel leaves Connected, stops once
    /// it is back, and stays stopped once signed out.
    @Test func pollingRunsOnlyWhileTheChannelIsDown() async throws {
        let (backend, _) = try await Self.connected()
        #expect(await backend.poller == nil)  // no realtime channel, nothing to stand in for
        await backend.channelChanged(.reconnecting)
        let first = try #require(await backend.poller)
        await backend.channelChanged(.connecting)
        #expect(await backend.poller == first)  // still down: the same loop keeps its interval
        await backend.channelChanged(.connected)
        #expect(await backend.poller == nil && first.isCancelled)
        await backend.channelChanged(.reconnecting)
        #expect(await backend.poller != nil)
        await backend.channelChanged(.signedOut)
        #expect(await backend.poller == nil)
        _ = await Self.drain(backend)
    }
    @Test func failedCatchUpAsksForResync() async throws {
        let (backend, _) = try await Self.connected([
            try Self.proto(Dynamite_CatchUpResponse.with { $0.status = .abortedFromRevisionTooOld })
        ])
        await backend.handle(Self.ready)
        await backend.handle(.with { $0.event.userRevision.timestamp = 100 })
        await backend.handle(Self.ready)
        #expect(await Self.drain(backend).contains(.resync))
    }
    @Test func readyWithoutAnyRevisionResyncsWithoutCatchUp() async throws {
        let (backend, exchange) = try await Self.connected()
        await backend.handle(Self.ready)
        await backend.handle(Self.ready)
        #expect(await Self.drain(backend).contains(.resync))
        #expect(!exchange.requests.contains { $0.url?.path == "/api/catch_up_user" })
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func groupRevisionAlsoDrivesCatchUp() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_CatchUpResponse.with { $0.status = .completed })
        ])
        await backend.handle(Self.ready)
        await backend.handle(.with { $0.event.groupRevision.timestamp = 100 })
        await backend.handle(Self.ready)
        #expect(!(await Self.drain(backend)).contains(.resync))
        #expect(exchange.requests.last?.url?.path == "/api/catch_up_user")
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func reconnectAfterSignInDoesNotCatchUp() async throws {
        let again = try Self.proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me" })
        let (backend, _) = try await Self.connected([again])
        await backend.handle(Self.ready)
        _ = try await backend.connect()  // signed in again: a fresh load follows
        await backend.handle(Self.ready)
        #expect(!(await Self.drain(backend)).contains(.resync))
    }
    @Test func deletingAReplyLowersTheHeadCount() async throws {
        let (backend, _) = try await Self.connected()
        func push(_ type: Dynamite_EventBody.EventType, _ id: String) -> Dynamite_StreamEventsResponse {
            .with {
                $0.event.groupID.spaceID.spaceID = "x"
                $0.event.bodies = [
                    .with {
                        $0.eventType = type
                        if type == .messageDeleted {
                            $0.messageDeleted.messageID.parentID.topicID.topicID = "t1"
                            $0.messageDeleted.messageID.messageID = id
                        } else {
                            $0.messagePosted.message = Self.message(id, topic: "t1", at: id == "h1" ? 1 : 2)
                        }
                    }
                ]
            }
        }
        await backend.handle(push(.messagePosted, "h1"))
        await backend.handle(push(.messagePosted, "r1"))
        await backend.handle(push(.messageDeleted, "r1"))
        let heads = await Self.drain(backend).compactMap {
            if case .messageUpserted(let upserted) = $0, upserted.id == "space/x/t1/h1" {
                upserted.replyCount
            } else {
                nil
            }
        }
        #expect(heads == [0, 1, 0])
    }
}

extension NetworkTests.DynamiteBackendTests {
    private static func topic(_ id: String, sort: Int64) -> Dynamite_Topic {
        .with {
            $0.sortTime = sort
            $0.replies = [message(id, topic: id, at: sort)]
        }
    }
    @Test func olderHistoryAnchorsOnOldestSortTime() async throws {
        let recent = Dynamite_ListTopicsResponse.with {
            $0.topics = [Self.topic("t3", sort: 300), Self.topic("t2", sort: 200)]
        }
        let older = Dynamite_ListTopicsResponse.with {
            $0.topics = [Self.topic("t2", sort: 200), Self.topic("t1", sort: 100)]
            $0.containsFirstTopic = true
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(recent), try Self.proto(older)])
        let first = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        #expect(first.hasMore)
        let page = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        #expect(page.messages.map(\.id) == ["dm/a/t2/t2", "dm/a/t1/t1"] && !page.hasMore)
        #expect(exchange.requests.filter { $0.url?.path == "/api/list_topics" }.count == 2)
        let last = try await backend.messages(in: "dm/a", thread: nil, before: .now)  // nothing older: no request
        #expect(last.messages.isEmpty && !last.hasMore)
        #expect(exchange.requests.filter { $0.url?.path == "/api/list_topics" }.count == 2)
    }
    @Test func sendsCarryClientGeneratedMessageIDs() async throws {
        let topic = try Self.proto(
            Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(
            Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, _) = try await Self.connected([topic, reply])
        let sent = try await backend.send(MessageDraft(text: "hi", localID: "local-1"), to: "dm/a", thread: nil)
        #expect(sent.id == "dm/a/m9/m9")
        let replied = try await backend.send(
            MessageDraft(text: "re", localID: "local-2"), to: "dm/a", thread: ThreadID(head: sent.id))
        #expect(replied.threadID == ThreadID(head: sent.id))
    }
    @Test func resendingADraftReusesItsClientMessageID() async throws {
        let topic = try Self.proto(
            Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(
            Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, exchange) = try await Self.connected([topic, topic, reply, reply])
        func sent(_ path: String) -> [Data] { exchange.requests.filter { $0.url?.path == path }.map(Self.body) }
        for _ in 0..<2 {
            _ = try await backend.send(MessageDraft(text: "hi", localID: "local-1"), to: "dm/a", thread: nil)
        }
        for _ in 0..<2 {
            _ = try await backend.send(MessageDraft(text: "re", localID: "local-2"), to: "dm/a", thread: "dm/a/m9/m9")
        }
        let topics = try sent("/api/create_topic").map {
            try Dynamite_CreateTopicRequest(serializedBytes: $0).topicAndMessageID
        }
        let replies = try sent("/api/create_message").map {
            try Dynamite_CreateMessageRequest(serializedBytes: $0).messageID
        }
        #expect(topics.count == 2 && topics[0] == topics[1] && topics[0].count == 11)  // a retry is deduped by Google, not posted twice
        #expect(replies.count == 2 && replies[0] == replies[1] && replies[0] != topics[0])
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func sharedLinksComeFromListAttachmentsAndPageFromTheLastItem() async throws {
        func item(_ url: String, message: String) -> Dynamite_AttachmentItem {
            .with { entry in
                entry.annotation.urlMetadata.url.url = url
                entry.annotation.urlMetadata.title = ""  // no preview: still listed
                entry.messageID.parentID.topicID.topicID = "t-\(message)"
                entry.messageID.messageID = message
                entry.createTime = 1_700_000_000_000_000
                entry.creator.id = "u2"
            }
        }
        let first = Dynamite_ListAttachmentsResponse.with { response in
            response.results = [
                .with {
                    $0.category = .link
                    $0.items = (0..<20).map { item("https://example.com/\($0)", message: "m\($0)") }
                }
            ]
        }
        let members = Dynamite_GetMembersResponse.with {
            $0.memberProfiles = [
                .with {
                    $0.member.user.userID.id = "u2"
                    $0.member.user.name = "Alex"
                }
            ]
        }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(first), try Self.proto(members), try Self.proto(Dynamite_ListAttachmentsResponse()),
        ])
        let page = try await backend.shared(.links, in: "space/s", after: nil)
        #expect(page.items.count == 20 && page.hasMore)
        #expect(
            page.items[0].attachment.kind == .link && page.items[0].attachment.name == "example.com"
                && page.items[0].sender == "Alex")
        #expect(page.items[19].messageID == "space/s/t-m19/m19")
        let sent = try Dynamite_ListAttachmentsRequest(
            serializedBytes: Self.body(
                try #require(exchange.requests.first { $0.url?.path == "/api/list_attachments" })))
        #expect(
            sent.categories == [.link] && sent.pageSize == 20 && sent.direction == 1 && sent.includeAnchor
                && !sent.hasAnchor)
        let next = try await backend.shared(.links, in: "space/s", after: page.items.last)
        #expect(next.items.isEmpty && !next.hasMore)
        let paged = try Dynamite_ListAttachmentsRequest(
            serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(
            paged.anchor.messageID == "m19" && paged.anchor.parentID.topicID.topicID == "t-m19" && !paged.includeAnchor)
    }
    @Test func reactorsComeFromListReactorsWithNamesResolved() async throws {
        let listed = Dynamite_ListReactorsResponse.with {
            $0.reactors = ["u2", "me", ""].map { id in .with { $0.id = id } }
        }
        let members = Dynamite_GetMembersResponse.with {
            $0.memberProfiles = [
                .with {
                    $0.member.user.userID.id = "u2"
                    $0.member.user.name = "Alex"
                }
            ]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(listed), try Self.proto(members)])
        let people = try await backend.reactors(of: "space/s/t1/m1", emoji: "👍", custom: nil)
        #expect(people.map(\.name) == ["Alex", "Dave"])
        let sent = try Dynamite_ListReactorsRequest(
            serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/list_reactors" })))
        #expect(sent.messageID.messageID == "m1" && sent.messageID.parentID.topicID.topicID == "t1")
        #expect(sent.emoji.unicode == "👍" && sent.pageSize == 100 && sent.hasRequestHeader)
    }
    @Test func searchMapsResultsAndCursor() async throws {
        var hit = Self.message("m1", topic: "t1", at: 3)
        hit.id.parentID.topicID.groupID.dmID.dmID = "zz"  // a conversation not in the sidebar
        let response = Dynamite_SearchMessagesV2Response.with {
            $0.cursor = "next"
            $0.results.items = [.with { $0.message = hit }, .with { _ in }]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(response)])
        let page = try await backend.searchMessages(matching: "hello", filters: SearchFilters(), cursor: nil)
        #expect(page.messages.map(\.id) == ["dm/zz/t1/m1"] && page.messages[0].conversationID == "dm/zz")
        #expect(page.cursor == "next")
        #expect(exchange.requests.last?.url?.path == "/api/search_messages_v2")
        let sent = try Dynamite_SearchMessagesV2Request(
            serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(!sent.filter.hasScope && !sent.hasSort)  // everywhere: an empty filter, no sort
    }
    /// Search in one conversation: the filter's scope names its group, with the relevance sort Google requires alongside it.
    @Test func searchInAConversationScopesTheFilterAndSorts() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_SearchMessagesV2Response())])
        _ = try await backend.searchMessages(
            matching: "hello", filters: SearchFilters(saidIn: ["space/s9"]), cursor: nil)
        let sent = try Dynamite_SearchMessagesV2Request(
            serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(
            sent.filter.scope.conversations.map(\.groupID.spaceID.spaceID) == ["s9"]
                && sent.filter.scope.conversations[0].kind == 1)
        #expect(sent.sort.operator == .relevance && sent.query == "hello")
    }
}

extension NetworkTests.DynamiteBackendTests {
    private static func page(_ topics: [(String, Int64)], first: Bool = false) throws -> StubExchange.Reply {
        try proto(
            Dynamite_ListTopicsResponse.with { response in
                response.topics = topics.map { id, sort in
                    .with {
                        $0.sortTime = sort
                        $0.replies = [message(id, topic: id, at: sort)]
                    }
                }
                response.containsFirstTopic = first
            })
    }
    @Test func olderPagingRestartsAfterReload() async throws {
        let recent = try Self.page([("t3", 300), ("t2", 200)])
        let (backend, exchange) = try await Self.connected([
            recent, try Self.page([("t1", 100)]), recent, try Self.page([("t1", 100)]),
        ])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        _ = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)  // reselect / resync
        _ = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        let last = try #require(exchange.requests.last { $0.url?.path == "/api/list_topics" })
        #expect(try Dynamite_ListTopicsRequest(serializedBytes: Self.body(last)).filter.olderThan == 200)
    }
    @Test func olderPageWithNothingOlderStops() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.page([("t3", 300), ("t2", 200)]), try Self.page([("t2", 200)]),
        ])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        #expect(!(try await backend.messages(in: "dm/a", thread: nil, before: .now)).hasMore)
        _ = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        #expect(exchange.requests.filter { $0.url?.path == "/api/list_topics" }.count == 2)
    }
    @Test func searchHitOnReplyPointsAtItsThread() async throws {
        var reply = Self.message("r1", topic: "t1", at: 3)
        reply.id.parentID.topicID.groupID.dmID.dmID = "zz"
        var head = Self.message("t2", topic: "t2", at: 4)
        head.id.parentID.topicID.groupID.dmID.dmID = "zz"
        let response = Dynamite_SearchMessagesV2Response.with {
            $0.results.items = [.with { $0.message = reply }, .with { $0.message = head }]
        }
        let (backend, _) = try await Self.connected([try Self.proto(response)])
        let page = try await backend.searchMessages(matching: "x", filters: SearchFilters(), cursor: nil)
        #expect(page.messages.map(\.threadID) == ["dm/zz/t1/t1", nil])
    }
    @Test func editingAReplyInAnUnloadedThreadKeepsItInTheThread() async throws {
        var edited = Self.message("r1", topic: "t1", at: 2, by: "me")
        edited.textBody = "new"
        let (backend, _) = try await Self.connected([
            try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })
        ])
        try await backend.edit("space/x/t1/r1", text: "new")
        #expect(Self.upserts(await Self.drain(backend)).last?.threadID == "space/x/t1/t1")
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func unloadedThreadFetchesNewestReplies() async throws {
        let newest = Dynamite_ListMessagesResponse.with {
            $0.messages = [Self.message("t1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)]
            $0.containsFirstMessage = true
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(newest)])
        let page = try await backend.messages(in: "dm/zz", thread: "dm/zz/t1/t1", before: nil)
        #expect(page.messages.map(\.id) == ["dm/zz/t1/r1"] && !page.hasMore)
        let request = try Dynamite_ListMessagesRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.filter.olderThan == 9_007_199_254_740_991)
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func historyRequestsTopicMetadataAndUsesTheRealReplyCount() async throws {
        let topics = Dynamite_ListTopicsResponse.with {
            $0.topics = [
                .with {
                    $0.sortTime = 3
                    $0.replies = [Self.message("t1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)]
                    $0.topicReadState.replySummary.totalReplyCount = 41
                }
            ]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(topics)])
        let page = try await backend.messages(in: "space/x", thread: nil, before: nil)
        #expect(page.messages[0].replyCount == 41)
        let request = try Dynamite_ListTopicsRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.fetchOptions == [.topicMetadata, .readReceipts])
    }
}

extension NetworkTests.DynamiteBackendTests {
    @Test func openingAThreadShowsItsNewestRepliesNotTheOldestUnread() async throws {
        // list_topics returns the OLDEST 20 unread replies (r1…r20) of a 41-reply thread.
        let topics = Dynamite_ListTopicsResponse.with {
            $0.topics = [
                .with {
                    $0.sortTime = 41
                    $0.replies =
                        [Self.message("t1", topic: "t1", at: 0)]
                        + (1...20).map { Self.message("r\($0)", topic: "t1", at: Int64($0)) }
                    $0.topicReadState.replySummary.totalReplyCount = 41
                }
            ]
        }
        let newest = Dynamite_ListMessagesResponse.with {
            $0.messages = (12...41).map { Self.message("r\($0)", topic: "t1", at: Int64($0)) }
        }
        let older = Dynamite_ListMessagesResponse.with {
            $0.messages = (1...12).map { Self.message("r\($0)", topic: "t1", at: Int64($0)) }
            $0.containsFirstMessage = true
        }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(topics), try Self.proto(newest), try Self.proto(older),
        ])
        _ = try await backend.messages(in: "space/x", thread: nil, before: nil)
        let opened = try await backend.messages(in: "space/x", thread: "space/x/t1/t1", before: nil)
        #expect(
            opened.messages.last?.id == "space/x/t1/r41" && opened.messages.first?.id == "space/x/t1/r12"
                && opened.hasMore)
        let opening = try Dynamite_ListMessagesRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(opening.filter.olderThan == 9_007_199_254_740_991)
        let page = try await backend.messages(in: "space/x", thread: "space/x/t1/t1", before: .now)
        #expect(page.messages.map(\.id) == (1...11).map { "space/x/t1/r\($0)" } && !page.hasMore)
        #expect(
            try Dynamite_ListMessagesRequest(serializedBytes: Self.body(try #require(exchange.requests.last))).filter
                .olderThan == 12)
    }
}

extension NetworkTests.DynamiteBackendTests {
    /// A send whose first attempt reached the server: the retry's id is taken, but the message is already here, so it counts as sent.
    @Test func aRetryOfAMessageTheServerAlreadyHasSucceeds() async throws {
        let id = DynamiteID.messageID(for: "local-1")
        let reply = DynamiteID.messageID(for: "local-2")
        let history = try Self.proto(
            Dynamite_ListTopicsResponse.with {
                $0.topics = [.with { $0.replies = [Self.message(id, topic: id, at: 5, by: "me")] }]
            })
        let replies = try Self.proto(
            Dynamite_ListMessagesResponse.with { $0.messages = [Self.message(reply, topic: id, at: 6, by: "me")] })
        let (backend, _) = try await Self.connected([history, .init(status: 400), replies, .init(status: 400)])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        let sent = try await backend.send(MessageDraft(text: id, localID: "local-1"), to: "dm/a", thread: nil)
        #expect(sent.id == DynamiteID.message("dm/a", topic: id, message: id))
        _ = try await backend.messages(in: "dm/a", thread: ThreadID(head: sent.id), before: nil)
        let sentReply = try await backend.send(
            MessageDraft(text: reply, localID: "local-2"), to: "dm/a", thread: ThreadID(head: sent.id))
        #expect(
            sentReply.id == DynamiteID.message("dm/a", topic: id, message: reply)
                && sentReply.threadID == ThreadID(head: sent.id))
    }
}

extension NetworkTests.DynamiteBackendTests {
    /// Others see our read receipt from this time, which they compare with server create times, so it is the newest
    /// message's time rather than the Mac's clock, and it never moves back.
    @Test func markReadSendsTheNewestMessageTimeAndNeverGoesBack() async throws {
        let history = try Self.proto(
            Dynamite_ListTopicsResponse.with {
                $0.topics = [
                    .with { $0.replies = [Self.message("a", topic: "a", at: 1_700_000_000_000_001, by: "u1")] },
                    .with {
                        $0.replies = [
                            Self.message("b", topic: "b", at: 1_700_000_000_000_009, by: "u1"),
                            Self.message("c", topic: "b", at: 1_700_000_000_000_042, by: "u1"),
                        ]
                    },
                ]
            })
        let older = try Self.proto(
            Dynamite_ListTopicsResponse.with {
                $0.topics = [.with { $0.replies = [Self.message("z", topic: "z", at: 7, by: "u1")] }]
            })
        let done = try Self.proto(Dynamite_MarkGroupReadstateResponse())
        let (backend, exchange) = try await Self.connected([history, done, older, done])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        try await backend.markRead("dm/a")
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)  // a reload that only holds an older message
        try await backend.markRead("dm/a")
        let sent = try exchange.requests.filter { $0.url?.path == "/api/mark_group_readstate" }
            .map { try Dynamite_MarkGroupReadstateRequest(serializedBytes: Self.body($0)).lastReadTime }
        #expect(sent == [1_700_000_000_000_042, 1_700_000_000_000_042])
    }
}

extension NetworkTests.DynamiteBackendTests {
    /// Replying from a search hit, whose thread head was never loaded: the reply must not be taken for the head,
    /// or the next reply would be filed under it and pushed as a bumped head.
    @Test func replyingInAnUnloadedThreadDoesNotMakeTheReplyItsHead() async throws {
        let first = Dynamite_CreateMessageResponse.with {
            $0.message = Self.message("r5", topic: "t1", at: 6, by: "me")
        }
        let second = Dynamite_CreateMessageResponse.with {
            $0.message = Self.message("r6", topic: "t1", at: 7, by: "me")
        }
        let (backend, _) = try await Self.connected([try Self.proto(first), try Self.proto(second)])
        _ = try await backend.send(MessageDraft(text: "r5", localID: "local-5"), to: "space/x", thread: "space/x/t1/t1")
        let reply = try await backend.send(
            MessageDraft(text: "r6", localID: "local-6"), to: "space/x", thread: "space/x/t1/t1")
        #expect(reply.threadID == "space/x/t1/t1")
        #expect(Self.upserts(await Self.drain(backend)).isEmpty)  // no "head" r5 with a bumped reply count
    }
}

extension NetworkTests.DynamiteBackendTests {
    /// Google names someone a placeholder until they accept a DM; their first live message brings their real profile.
    private static func pushedDM(_ message: Dynamite_Message) -> Dynamite_StreamEventsResponse {
        .with {
            $0.event.groupID.dmID.dmID = "d"
            $0.event.bodies = [
                .with {
                    $0.eventType = .messagePosted
                    $0.messagePosted.message = message
                }
            ]
        }
    }
    @Test func aSendersFirstLiveMessageRefreshesTheirProfile() async throws {
        let anonymous = Dynamite_GetMembersResponse.with {
            $0.memberProfiles = [
                .with {
                    $0.member.user.userID.id = "u2"
                    $0.member.user.name = "Anonymous User"
                }
            ]
        }
        let named = Dynamite_GetMembersResponse.with {
            $0.memberProfiles = [
                .with {
                    $0.member.user.userID.id = "u2"
                    $0.member.user.name = "Maria"
                }
            ]
        }
        let listed = Dynamite_ListReactorsResponse.with { $0.reactors = [.with { $0.id = "u2" }] }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(listed), try Self.proto(anonymous), try Self.proto(named),
        ])
        _ = try await backend.reactors(of: "space/s/t1/m1", emoji: "👍", custom: nil)  // u2 known, as the placeholder
        await backend.handle(Self.pushedDM(Self.message("m2", topic: "m2", at: 5, by: "u2")))
        await backend.handle(Self.pushedDM(Self.message("m3", topic: "m3", at: 6, by: "u2")))
        let events = await Self.drain(backend)
        #expect(events.contains(.resync))
        #expect(Self.upserts(events).map(\.sender.name) == ["Maria", "Maria"])
        #expect(exchange.requests.filter { $0.url?.path == "/api/get_members" }.count == 3)  // connect, the reactors, one re-read: not per message
    }
}

struct RequestHeaderTests {
    /// Google switches off every capability a declared list leaves out (a list of 17 alone dropped forwards, group DM
    /// names and Ask Gemini), so every RPC declares web's whole list, each field FULLY_SUPPORTED (2).
    @Test func everyRequestDeclaresWebsWholeCapabilityList() throws {
        let caps = try Dynamite_ClientFeatureCapabilities(
            serializedBytes: try DynamiteClient.header.clientFeatureCapabilities.serializedBytes() as Data)
        var declared: [Int: UInt64] = [:]
        var bytes = Array(try caps.serializedBytes() as Data)[...]
        func varint() -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while let byte = bytes.popFirst() {
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { break }
                shift += 7
            }
            return value
        }
        while !bytes.isEmpty {
            let key = varint()
            declared[Int(key >> 3)] = varint()
        }
        #expect(declared.keys.sorted() == DynamiteClient.webCapabilities)
        #expect(declared.values.allSatisfy { $0 == 2 })
        #expect(
            DynamiteClient.webCapabilities.count == 48 && DynamiteClient.webCapabilities.contains(17)
                && DynamiteClient.webCapabilities.contains(53))
        #expect(DynamiteClient.header.clientType == .web && DynamiteClient.header.traceID == 0)
    }
}

extension NetworkTests.DynamiteBackendTests {
    /// As Google Chat sends it: field 11 = 2. Without it, list_topics on the Ask Gemini DM fails (HTTP 500) once
    /// capabilities 6 and 17 are declared.
    @Test func listTopicsSendsField11AsGoogleChatDoes() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_ListTopicsResponse.with { $0.containsFirstTopic = true })
        ])
        _ = try await backend.messages(in: "dm/gemini", thread: nil, before: nil)
        let sent = try Dynamite_ListTopicsRequest(
            serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/list_topics" })))
        #expect(sent.field11 == 2)
    }
}
