import AppKit
import Testing

@testable import Parley

@MainActor struct ReactionStripTests {
    /// The More button's color is baked into its image, not applied as a tint: on macOS 15 a menu item's view
    /// drew the tinted template symbol blank.
    @Test func moreButtonShowsAnUntintedSymbol() throws {
        let strip = ReactionStrip(emoji: ["👍"], react: { _ in }, more: {})
        let image = try #require(strip.moreButton.image)
        #expect(!image.isTemplate)
        #expect(strip.moreButton.contentTintColor == nil)
        #expect(image.size.width > 0)
    }
}
