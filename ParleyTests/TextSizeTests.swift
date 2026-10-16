import AppKit
import Testing
@testable import Parley

/// View ▸ Bigger and Smaller scale message text in the timeline and the composer, in steps, as Mail's do.
struct TextSizeTests {
    @Test func stepsGoUpAndDownAndStopAtTheEnds() {
        #expect(TextSize.next(from: 1, by: 1) > 1 && TextSize.next(from: 1, by: -1) < 1)
        #expect(TextSize.next(from: TextSize.steps.last!, by: 1) == TextSize.steps.last!)
        #expect(TextSize.next(from: TextSize.steps.first!, by: -1) == TextSize.steps.first!)
        #expect(TextSize.next(from: 1.07, by: 1) == TextSize.next(from: 1, by: 1))   // an odd saved value snaps to its step
    }
    @Test func messageTextFollowsTheScale() throws {
        func size(_ scale: CGFloat, _ formatting: [TextStyleRange] = []) throws -> CGFloat {
            let styled = MessageTextStyle.styled("Hello world", formatting, own: false, scale: scale)
            return try #require(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        }
        #expect(try size(1) == 14)
        #expect(try size(1.5) == 21)
        #expect(try size(1.5, [TextStyleRange(style: .code, start: 0, length: 5)]) == 19.5)
        // Measured heights follow, so rows grow with the text.
        let small = MessageTextStyle.measure(MessageTextStyle.styled("Hello world", own: false, scale: 1), width: 300).size.height
        let big = MessageTextStyle.measure(MessageTextStyle.styled("Hello world", own: false, scale: 1.5), width: 300).size.height
        #expect(big > small)
    }
    @MainActor @Test func theComposerTypesAtTheScale() throws {
        let font = try #require(ComposerTextView.visual([:], scale: 1.3)[.font] as? NSFont)
        #expect(abs(font.pointSize - 18.2) < 0.01)
    }
    /// A message already on screen takes the new size: the text view doesn't keep the text it showed at the old one.
    @MainActor @Test func aShownMessageTakesTheNewSize() throws {
        let view = NSTextView(usingTextLayoutManager: false)
        NativeMessageText.show("Hello world", own: false, in: view, scale: 1)
        NativeMessageText.show("Hello world", own: false, in: view, scale: 1.5)
        let font = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 21)
    }
}
