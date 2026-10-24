import AppKit
import Testing

@testable import Parley

@MainActor struct WritingToolsTests {
    /// Seen live: macOS drew a Siri / Writing Tools badge at the corner of message bubbles. Messages are read-only.
    @Test func messageTextOffersNoWritingTools() {
        let view = MessageRowView()
        if #available(macOS 15.2, *) { #expect(view.textView.writingToolsBehavior == .none) }
    }
}
