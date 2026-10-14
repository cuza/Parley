import Foundation
import Testing
@testable import Parley

/// Ask Gemini's home greets by time of day and first name, as web Chat does.
struct GeminiPaneTests {
    static func at(_ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: 30))!
    }
    @Test func theGreetingFollowsTheTimeOfDay() {
        #expect(GeminiPane.greeting(name: "Dave Moreno", at: Self.at(9)) == "Good morning, Dave")
        #expect(GeminiPane.greeting(name: "Dave Moreno", at: Self.at(14)) == "Good afternoon, Dave")
        #expect(GeminiPane.greeting(name: "Dave Moreno", at: Self.at(20)) == "Good evening, Dave")
        #expect(GeminiPane.greeting(name: "", at: Self.at(20)) == "Good evening")
    }
}
