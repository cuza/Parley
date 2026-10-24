import AppKit
import SwiftUI
import Testing

@testable import Parley

struct EmojiUsageTests {
    private func usage() -> EmojiUsage {
        let name = "EmojiUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return EmojiUsage(defaults: defaults)
    }
    @Test func withoutHistoryTheQuickReactionsAreTheDefaults() {
        #expect(usage().top(6) == EmojiUsage.defaults)
        #expect(usage().top(3) == Array(EmojiUsage.defaults.prefix(3)))
    }
    @Test func theMostUsedComeFirstThenTheDefaults() {
        let usage = usage()
        usage.record("🦊")
        usage.record("🦊")
        usage.record("🎉")
        usage.record("😂")
        #expect(usage.top(6) == ["🦊", "😂", "🎉", "👍", "❤️", "😮"])  // on a tie a default comes first
        #expect(usage.top(9) == ["🦊", "😂", "🎉", "👍", "❤️", "😮", "😢", "🙏"])  // only the defaults pad it
    }
    @Test func countsPersistInTheDefaults() {
        let first = usage()
        first.record("🦊")
        #expect(EmojiUsage(defaults: first.defaults).top(1) == ["🦊"])
    }
}
