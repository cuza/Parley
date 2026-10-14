import Foundation
import Testing
@testable import Parley

/// Block and report, as Google Chat's Block and report dialog and its Report this message send them.
extension AuthTests {
    @Test func blockingAPersonNamesThemAndTheirDM() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_BlockEntityResponse()), try Self.proto(Dynamite_BlockEntityResponse())])
        try await backend.setBlocked(true, person: "u1", dm: "dm/d1", report: false)
        let sent = try Dynamite_BlockEntityRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(exchange.requests.last?.url?.path == "/api/block_entity")
        #expect(sent.userID.id == "u1" && sent.blocked && sent.hasReport && !sent.report && sent.dmGroupID.dmID.dmID == "d1" && !sent.hasGroupID)
        try await backend.setBlocked(false, person: "u1", dm: "dm/d1", report: false)
        let undo = try Dynamite_BlockEntityRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(!undo.blocked && !undo.report && undo.userID.id == "u1")
    }
    @Test func blockingASpaceNamesTheSpace() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_BlockEntityResponse())])
        try await backend.setBlocked(true, space: "space/s9", report: true)
        let sent = try Dynamite_BlockEntityRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(sent.groupID.spaceID.spaceID == "s9" && sent.blocked && sent.report && !sent.hasUserID)
    }
    @Test func theBlockedListsComeFromTheirOwnCalls() async throws {
        let people = Dynamite_ListBlockedUsersResponse.with { $0.userIds = [.with { $0.id = "u7" }] }
        let rooms = Dynamite_ManageBlockedRoomsResponse.with { $0.rooms = [.with { $0.groupID.spaceID.spaceID = "s3"; $0.name = "Spam"; $0.blockedTime = 2_000_000 }] }
        let (backend, _) = try await Self.connected([try Self.proto(people), try Self.proto(rooms)])
        #expect(try await backend.blockedPeople() == ["u7"])
        let spaces = try await backend.blockedSpaces()
        #expect(spaces == [BlockedSpace(id: "space/s3", name: "Spam", blocked: Date(timeIntervalSince1970: 2))])
    }
    @Test func aReportNamesTheMessageItsUpdateTimeAndTheReason() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ReportMessageResponse())])
        let message = Message(id: "space/s9/t1/m2", conversationID: "space/s9", sender: Person(id: "u1", name: "Maria"), text: "x", lastUpdateMicros: 5_000)
        try await backend.report(message, reason: .spam, explanation: "")
        let sent = try Dynamite_ReportMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(sent.messageID.messageID == "m2" && sent.messageUpdateTime.micros == 5_000 && sent.reason.kind == .spam)
        #expect(sent.hasExplanation && !sent.explanation.hasText)
    }
}

@MainActor struct BlockStoreTests {
    @Test func blockingAPersonLeavesTheirDMAndHidesTheirMessages() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.block(person: "maria", report: false)
        #expect(store.blockedPeople.contains("maria") && !store.conversations.contains { $0.id == "maria" })
        let hers = Message(id: "x", conversationID: "design", sender: Person(id: "maria", name: "Maria Chen"), text: "secret", attachments: [Attachment(name: "a.png", kind: .image)])
        let shown = ChatStore.blockedView(hers)
        #expect(shown.text == "Message from a blocked person" && shown.attachments.isEmpty)
        await store.unblock(person: "maria")
        #expect(!store.blockedPeople.contains("maria"))
        #expect(await fake.changes.suffix(2) == ["block maria", "unblock maria"])
    }
    @Test func reportReasonsAreGooglesInItsOrder() {
        #expect(ReportReason.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 7, 6])
        #expect(ReportReason.other.title == "Something else")
    }
}
