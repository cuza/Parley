import Foundation
import Testing
@testable import Parley

/// Google Chat's own notify decision (WEB_PUSH_NOTIFICATION) against Parley's banner, logged where they differ.
struct NotifyComparisonTests {
    let start = Date(timeIntervalSince1970: 1_000)
    @Test func agreementsSayNothing() {
        var compare = NotifyComparison()
        #expect(compare.parley("m1", banner: true, detail: "dm", at: start).isEmpty)
        #expect(compare.google("m1", cause: 1, at: start).isEmpty)
        #expect(compare.google("m1", cause: 1, at: start).isEmpty)   // Google's second copy
        #expect(compare.parley("m2", banner: false, detail: "muted", at: start).isEmpty)
        #expect(compare.expire(at: start.addingTimeInterval(60)).isEmpty)
    }
    @Test func googleAloneIsADifferenceEitherWayRound() {
        var compare = NotifyComparison()
        _ = compare.parley("m1", banner: false, detail: "level forYou, new thread", at: start)
        #expect(compare.google("m1", cause: 3, at: start) == ["notify differs: Google yes (cause 3), Parley no (level forYou, new thread)"])
        #expect(compare.google("m2", cause: 2, at: start).isEmpty)   // Parley hasn't decided yet: wait for it
        #expect(compare.parley("m2", banner: false, detail: "app active", at: start) == ["notify differs: Google yes (cause 2), Parley no (app active)"])
    }
    @Test func parleyAloneShowsOnceGoogleHadTimeToSay() {
        var compare = NotifyComparison()
        _ = compare.parley("m1", banner: true, detail: "level all, new thread", at: start)
        #expect(compare.expire(at: start.addingTimeInterval(5)).isEmpty)
        #expect(compare.expire(at: start.addingTimeInterval(16)) == ["notify differs: Google no, Parley yes (level all, new thread)"])
        #expect(compare.expire(at: start.addingTimeInterval(30)).isEmpty)   // once
    }
}
