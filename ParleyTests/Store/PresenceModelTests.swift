import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Presence on its own, without a store: the clock comes in as arguments.
@MainActor struct PresenceModelTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func activityMarksAvailableButKeepsDoNotDisturb() {
        let presence = PresenceModel()
        presence.markActive("maria", at: at(0))
        presence.availability["alex"] = .doNotDisturb
        presence.markActive("alex", at: at(0))
        #expect(presence.availability == ["maria": .available, "alex": .doNotDisturb])
        #expect(presence.stale(["maria", "alex", "sam"], at: at(30)) == ["sam"])  // asked about Maria and Alex just now
        #expect(presence.stale(["maria"], at: at(60)) == ["maria"])
    }
    @Test func typingIsSentEveryFiveSecondsAndNeverWhereRefused() {
        let presence = PresenceModel()
        #expect(presence.shouldSendTyping(in: "maria/timeline", at: at(0)))
        presence.typingSent["maria/timeline"] = at(0)
        #expect(!presence.shouldSendTyping(in: "maria/timeline", at: at(4)))
        #expect(presence.shouldSendTyping(in: "maria/timeline", at: at(5)))
        presence.typingRefused.insert("space/timeline")
        #expect(!presence.shouldSendTyping(in: "space/timeline", at: at(60)))
    }
    @Test func typistsAndAppsTimeOut() {
        let presence = PresenceModel()
        presence.typing["launch/timeline"] = ["maria": at(0), "alex": at(5)]
        presence.activities["gemini/timeline"] = .init(person: "gemini", label: "Collecting info", at: at(0))
        presence.sweepTyping(at: at(9))
        #expect(presence.typists(in: "launch/timeline") == ["alex"])
        #expect(presence.activities["gemini/timeline"] != nil)
        presence.sweepTyping(at: at(16))
        #expect(presence.typing.isEmpty && presence.activities.isEmpty)
    }
    @Test func readersAreThoseWhoReadUpToTheMessage() {
        let presence = PresenceModel()
        presence.readReceipts["launch"] = ["maria": at(10), "alex": at(20)]
        #expect(presence.readers(in: "launch", upTo: at(15)) == ["alex"])
        #expect(presence.readers(in: "launch", upTo: at(5)) == ["alex", "maria"])
        #expect(presence.readers(in: "general", upTo: at(5)).isEmpty)
    }
}
