import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Pages and their bookkeeping on their own, without a store or a backend.
@MainActor struct TimelineModelTests {
    private func message(_ id: String, at seconds: TimeInterval, thread: ThreadID? = nil) -> Message {
        .fixture(id, id: MessageID(id), in: "launch", thread: thread, at: Date(timeIntervalSince1970: seconds))
    }

    @Test func aTimelineIsSortedAndKeptUntilMessagesChange() {
        let history = TimelineModel()
        history.messages = [message("b", at: 20), message("a", at: 10), message("r", at: 15, thread: "t")]
        #expect(history.timeline("launch", thread: nil, scope: "launch/timeline").map(\.id) == ["a", "b"])
        #expect(history.timelines["launch/timeline"] != nil)
        history.put(message("c", at: 5))
        #expect(history.timelines.isEmpty)
        #expect(history.timeline("launch", thread: nil, scope: "launch/timeline").map(\.id) == ["c", "a", "b"])
        history.put(message("c", at: 30))  // replaced, not added
        #expect(history.timeline("launch", thread: nil, scope: "launch/timeline").map(\.id) == ["a", "b", "c"])
    }
    @Test func aDetachedWindowEndsAtItsNewestPage() {
        let history = TimelineModel()
        history.messages = [message("a", at: 10), message("b", at: 20), message("live", at: 99)]
        history.extendWindow(
            "launch",
            MessagePage(messages: [message("a", at: 10), message("b", at: 20)], hasMore: true, hasNewer: true))
        #expect(history.detached == ["launch"])
        #expect(history.timeline("launch", thread: nil, scope: "launch/timeline").map(\.id) == ["a", "b"])
        history.extendWindow("launch", MessagePage(messages: [], hasMore: false, hasNewer: false))
        #expect(history.detached.isEmpty && history.windowEnds.isEmpty)
        #expect(history.timeline("launch", thread: nil, scope: "launch/timeline").map(\.id) == ["a", "b", "live"])
    }
    @Test func aLandedPageRecordsWhetherOlderOnesRemain() {
        let history = TimelineModel()
        history.landed("launch/timeline", hasMore: true)
        #expect(history.loaded == ["launch/timeline"] && history.hasMore == ["launch/timeline"])
        history.landed("launch/timeline", hasMore: false)
        #expect(history.hasMore.isEmpty)
        history.toggleTranscript("v")
        #expect(history.openTranscripts == ["v"])
        history.toggleTranscript("v")
        #expect(history.openTranscripts.isEmpty)
    }
}
