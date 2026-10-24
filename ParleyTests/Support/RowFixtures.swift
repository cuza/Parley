import Foundation

@testable import Parley
@testable import ParleyDomain

/// Timeline rows for layout and row view tests: one message from Alex, its text and place in a run chosen by the test.
enum RowFixtures {
    static let alex = Person(id: "alex", name: "Alex Example")
    static func row(
        _ text: String, sender: Person = alex, newDay: Bool = false, begins: Bool = true, ends: Bool = true,
        configure: (inout Message) -> Void = { _ in }
    ) -> TimelineRow {
        TimelineRow(
            message: .fixture(text, from: sender, configure: configure), begins: begins, ends: ends, newDay: newDay)
    }
    static let long = String(repeating: "A long message that wraps when the window is narrow. ", count: 8)
}
