import Foundation
import Testing
@testable import Parley

/// Pinned messages: a conversation's board, as Google Chat keeps it (ids made up).
struct PinnedMappingTests {
    @Test func aPinnedLabelMarksTheMessagePinned() throws {
        var proto = AuthTests.message("m1", topic: "t1", at: 1)
        #expect(DynamiteMapper.message(proto, in: "space/x", selfID: "me", people: [:])?.pinned == false)
        proto.messageLabels = [.with { $0.type = .pinned }]
        #expect(DynamiteMapper.message(proto, in: "space/x", selfID: "me", people: [:])?.pinned == true)
    }
    /// The service line Google Chat posts on a pin: ROOM_UPDATED with field 9 {1: 1, 2: 1, 3: {1: the message's id}}.
    @Test func aPinShowsAsAServiceLine() throws {
        let pinned: [UInt8] = try Dynamite_MessageId.with { $0.parentID.topicID.topicID = "t1"; $0.parentID.topicID.groupID.dmID.dmID = "d"; $0.messageID = "t1" }
            .serializedBytes()
        let update = Wire.ld(4, Wire.ld(1, Wire.str(1, "u2"))) + Wire.int(8, 1) + Wire.ld(9, Wire.int(1, 1) + Wire.int(2, 1) + Wire.ld(3, Wire.ld(1, pinned)))
        var proto = AuthTests.message("s1", topic: "s1", at: 2, by: "u2")
        proto.textBody = ""; proto.messageType = .systemMessage
        proto.annotations = [.with { $0.type = .roomUpdated; $0.roomUpdated = try! .init(serializedBytes: update) }]
        let people = ["u2": Person(id: "u2", name: "Maria", presence: .offline)]
        #expect(DynamiteMapper.systemText(proto, in: "dm/d", selfID: "me", people: people) == "Maria pinned a message to the board")
    }
}

extension AuthTests {
    /// Pin: apply_message_label {1 MessageId, 2 {1: PINNED, 3: 0}}; unpin: remove_message_label {1 MessageId, 2 {1: PINNED}}.
    @Test func pinningAppliesAndUnpinningRemovesThePinnedLabel() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ApplyMessageLabelResponse()), try Self.proto(Dynamite_RemoveMessageLabelResponse())])
        try await backend.setPinned(true, on: "space/x/t1/h1")
        try await backend.setPinned(false, on: "space/x/t1/h1")
        #expect(exchange.requests.suffix(2).map { $0.url?.path } == ["/api/apply_message_label", "/api/remove_message_label"])
        let id: [UInt8] = try DynamiteID.protoMessageID("space/x/t1/h1").serializedBytes()
        let bodies = try exchange.requests.suffix(2).map { [UInt8](Self.body($0)) }
        #expect(bodies[0] == Wire.ld(1, id) + Wire.ld(2, Wire.int(1, 2) + Wire.int(3, 0)) + Wire.ld(100, Self.header))
        #expect(bodies[1] == Wire.ld(1, id) + Wire.ld(2, Wire.int(1, 2)) + Wire.ld(100, Self.header))
    }
    /// get_chat_board as Google Chat asks for it: {1 GroupId, 3 {4 {1: 5, 2: 2, 3: true}, 5 {1: 3, 2: true}}}; the pinned
    /// messages come back at field 4 {1 repeated Message}.
    @Test func theBoardListsThePinnedMessages() async throws {
        var pinned = Self.message("m1", topic: "m1", at: 5)
        pinned.id.parentID.topicID.groupID.spaceID.spaceID = "x"
        pinned.messageLabels = [.with { $0.type = .pinned }]
        let reply = Wire.ld(1, Wire.int(2, 1)) + Wire.ld(4, Wire.ld(1, try pinned.serializedBytes()))   // a section (1) is not used
        let (backend, exchange) = try await Self.connected([.init(headers: ["Content-Type": "application/x-protobuf"], data: Data(reply))])
        let messages = try await backend.pinnedMessages(in: "space/x")
        #expect(messages.map(\.id) == ["space/x/m1/m1"] && messages.allSatisfy(\.pinned))
        #expect(try Self.body(exchange, "get_chat_board") == Wire.ld(1, Wire.ld(1, Wire.str(1, "x")))
                + Wire.ld(3, Wire.ld(4, Wire.int(1, 5) + Wire.int(2, 2) + Wire.int(3, 1)) + Wire.ld(5, Wire.int(1, 3) + Wire.int(2, 1)))
                + Wire.ld(100, Self.header))
    }
}

/// Pinning from the timeline and the board in the info panel, against the fake backend.
@MainActor
struct PinnedStoreTests {
    @Test func pinningMarksTheMessageAndListsItOnTheBoard() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("alex")
        let message = try #require(store.messages.first { $0.conversationID == "alex" && !$0.isSystem })
        await store.loadPinned("alex")
        #expect(store.pinned["alex"]?.isEmpty == true)
        await store.setPinned(true, message)
        await eventually { store.messages.first { $0.id == message.id }?.pinned == true && store.pinned["alex"]?.map(\.id) == [message.id] }   // the server's echo
        #expect(store.messages.first { $0.id == message.id }?.pinned == true && store.pinned["alex"]?.map(\.id) == [message.id])
        await store.setPinned(false, message)
        await eventually { store.messages.first { $0.id == message.id }?.pinned == false && store.pinned["alex"]?.isEmpty == true }
        #expect(store.messages.first { $0.id == message.id }?.pinned == false && store.pinned["alex"]?.isEmpty == true)
    }
    @Test func theBoardMarksLoadedMessages() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.select("alex")
        let message = try #require(store.messages.first { $0.conversationID == "alex" && !$0.isSystem })
        await fake.simulatePinned(message.id)   // pinned elsewhere
        await store.loadPinned("alex")
        #expect(store.messages.first { $0.id == message.id }?.pinned == true)
    }
}
