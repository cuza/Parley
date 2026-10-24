import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// The anonymous report of message shapes Parley doesn't draw: structure only, never content.
struct MessageShapesTests {
    private func flagged(_ text: String = "Secret text for Alice", type: Int32 = 9) -> Dynamite_Message {
        .with { built in
            built.id.messageID = "msg-id-424242"
            built.creator.userID.id = "user-id-777"
            built.creator.email = "alice@example.com"
            built.textBody = text
            built.messageType = .userMessage
            built.annotations = [
                .with {
                    $0.type = .url
                    $0.startIndex = 0
                    $0.length = 4
                }
            ]
            built.botResponses = [
                .with {
                    $0.type = type
                    $0.bot.name = "Secret App"
                    $0.setupURL = "https://setup.example.com/x"
                }
            ]
        }
    }
    @Test func theSkeletonCarriesNoContent() throws {
        var store = MessageShapes.Store()
        let fields = MessageCoverage.gaps(flagged(), selfID: "me")
        #expect(fields == ["19.1=9"])
        let added = store.record(flagged(), fields: fields)
        #expect(added)
        let json = try #require(
            String(
                data: MessageShapes.export(
                    store.entries, app: "1.0 (1)", os: "15.0", date: Date(timeIntervalSince1970: 0)), encoding: .utf8))
        for secret in [
            "Secret", "Alice", "alice@example.com", "msg-id-424242", "user-id-777", "setup.example.com", "424242",
            "777",
        ] {
            #expect(!json.contains(secret), "\(secret) leaked")
        }
        let skeleton = try #require(store.entries.first?.skeleton)
        #expect(skeleton.contains("28=1") && skeleton.contains("19{1=9") && skeleton.contains("11{1=1"))  // allow-listed enums kept
        #expect(skeleton.contains("10:L21"))  // the text: its length only
        #expect(store.entries.first?.fields == ["19.1=9"])
    }
    @Test func shapesAreDedupedAndCapped() {
        var store = MessageShapes.Store()
        let first = store.record(flagged("one"), fields: ["19.1=9"])
        #expect(first)
        let again = store.record(flagged("a longer text"), fields: ["19.1=9"])
        #expect(!again)  // same shape, another length
        let other = store.record(flagged(type: 5), fields: ["19.1=5"])
        #expect(other)
        for index in 0..<300 { _ = store.record(flagged(), fields: ["x\(index)"]) }
        #expect(store.entries.count == MessageShapes.cap)
    }
    /// A Drive comment card: some comment rows, and a widget Parley doesn't draw (field `kind`: a chip list, a grid…).
    private func drive(rows: Int, kind: UInt8 = 21) throws -> Dynamite_Message {
        let key = Int(kind) << 3 | 2
        let tag: [UInt8] = key < 0x80 ? [UInt8(key)] : [UInt8(key & 0x7F | 0x80), UInt8(key >> 7)]
        let input = try Dynamite_CardWidget(serializedBytes: tag + [7, 0x0A, 0x05] + Array("Reply".utf8))
        return .with { built in
            built.id.messageID = "m\(rows)"
            built.textBody = String(repeating: "mention ", count: rows)
            built.appAttachments = [
                .with {
                    $0.card.sections = [
                        .with { cardSection in
                            cardSection.widgets =
                                (0..<rows).map { row in .with { $0.decoratedText.text.html = "comment \(row)" } } + [
                                    input
                                ]
                        }
                    ]
                }
            ]
        }
    }
    private func flag(_ message: Dynamite_Message, in store: inout MessageShapes.Store) -> Bool {
        store.record(message, fields: MessageCoverage.gaps(message, selfID: "me"))
    }
    @Test func oneGapIsOneEntryWhateverElseTheMessageHolds() throws {
        var store = MessageShapes.Store()
        let first = flag(try drive(rows: 1), in: &store)
        let second = flag(try drive(rows: 4), in: &store)
        #expect(first && !second)
        #expect(
            store.entries.count == 1 && store.entries.first?.count == 2
                && store.entries.first?.fields == ["15.7.2.2.?21"])
        let other = flag(try drive(rows: 2, kind: 22), in: &store)  // another widget kind Parley doesn't draw
        #expect(other && store.entries.count == 2)
    }
    @Test func theSummaryCountsMessagesPerGapMostSeenFirst() {
        let entries = [
            MessageShapes.Entry(fields: ["15.7.2.2.13.?6", "19.1=5"], skeleton: "", count: 3),
            MessageShapes.Entry(fields: ["19.1=5"], skeleton: "", count: 2),
        ]
        #expect(MessageShapes.summary(entries) == ["19.1=5 — 5 messages", "15.7.2.2.13.?6 — 3 messages"])
        #expect(MessageShapes.summary([MessageShapes.Entry(fields: ["50"], skeleton: "")]) == ["50 — 1 message"])
    }
    @Test func theLogLineNamesOnlyFields() {
        #expect(
            MessageShapes.logLine(["19.1=9", "35"]) == "a message has content Parley doesn't draw: fields 19.1=9, 35")
    }
}
