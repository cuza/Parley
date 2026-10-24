import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Block and report, as Google Chat's Block and report dialog and its Report this message send them.
extension NetworkTests { @Suite struct BlockReportTests: NetworkSuite {} }

extension NetworkTests.BlockReportTests {
    @Test func blockingAPersonNamesThemAndTheirDM() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_BlockEntityResponse()), try Self.proto(Dynamite_BlockEntityResponse()),
        ])
        try await backend.setPersonBlocked(true, for: "u1", dm: "dm/d1", report: false)
        let sent = try Dynamite_BlockEntityRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(exchange.requests.last?.url?.path == "/api/block_entity")
        #expect(
            sent.userID.id == "u1" && sent.blocked && sent.hasReport && !sent.report && sent.dmGroupID.dmID.dmID == "d1"
                && !sent.hasGroupID)
        try await backend.setPersonBlocked(false, for: "u1", dm: "dm/d1", report: false)
        let undo = try Dynamite_BlockEntityRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(!undo.blocked && !undo.report && undo.userID.id == "u1")
    }
    @Test func blockingASpaceNamesTheSpace() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_BlockEntityResponse())])
        try await backend.setSpaceBlocked(true, for: "space/s9", report: true)
        let sent = try Dynamite_BlockEntityRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(sent.groupID.spaceID.spaceID == "s9" && sent.blocked && sent.report && !sent.hasUserID)
    }
    @Test func theBlockedListsComeFromTheirOwnCalls() async throws {
        let people = Dynamite_ListBlockedUsersResponse.with { $0.userIds = [.with { $0.id = "u7" }] }
        let rooms = Dynamite_ManageBlockedRoomsResponse.with {
            $0.rooms = [
                .with {
                    $0.groupID.spaceID.spaceID = "s3"
                    $0.name = "Spam"
                }
            ]
        }
        let (backend, _) = try await Self.connected([try Self.proto(people), try Self.proto(rooms)])
        #expect(try await backend.blockedPeople() == ["u7"])
        let spaces = try await backend.blockedSpaces()
        #expect(spaces == [BlockedSpace(id: "space/s3", name: "Spam")])
    }
    @Test func aReportNamesTheMessageItsUpdateTimeAndTheReason() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ReportMessageResponse())])
        let message = Message.fixture("x", id: "space/s9/t1/m2", from: .fixture("u1", name: "Maria"), in: "space/s9") {
            $0.lastUpdateMicros = 5_000
        }
        try await backend.reportMessage(message, reason: .spam, explanation: "")
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
        #expect(store.rooms.blockedPeople.contains("maria") && !store.rooms.conversations.contains { $0.id == "maria" })
        let hers = Message.fixture("secret", id: "x", in: "design", attachments: [.fixture(.image)])
        let shown = ChatStore.blockedView(hers)
        #expect(shown.text == "Message from a blocked person" && shown.attachments.isEmpty)
        await store.unblock(person: "maria")
        #expect(!store.rooms.blockedPeople.contains("maria"))
        #expect(await fake.changes.suffix(2) == ["block maria", "unblock maria"])
    }
    @Test func reportReasonsAreGooglesInItsOrder() {
        #expect(ReportReason.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 7, 6])
        #expect(ReportReason.other.title == "Something else")
    }
}
