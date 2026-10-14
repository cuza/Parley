import AppKit
import Testing
@testable import Parley

/// The composer keeps Writing Tools (macOS 15.2 and later, where the Mac offers them), and their rewrites come back as
/// plain text: the composer's formatting lives in its own attributes, which a rich rewrite's fonts would not carry.
@MainActor struct ComposerWritingToolsTests {
    @Test func theComposerOffersPlainWritingTools() throws {
        guard #available(macOS 15.2, *) else { return }
        let composer = try #require(NativeComposer.makeScrollView(delegate: nil).documentView as? ComposerTextView)
        #expect(composer.writingToolsBehavior == .default)
        #expect(composer.allowedWritingToolsResultOptions == .plainText)
    }
}
