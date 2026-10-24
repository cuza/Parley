import AppKit
import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct ComposerTextStyleTests {
    @Test func boldTogglesOnASelectionAndOff() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("hello world", [])
        view.setSelectedRange(NSRange(location: 6, length: 5))
        view.formatBold(nil)
        #expect(view.formatting == [TextStyleRange(style: .bold, start: 6, length: 5)])
        let font = view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        view.formatBold(nil)
        #expect(view.formatting.isEmpty)
    }
    @Test func aStyleAtTheCaretAppliesToWhatIsTypedNext() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("a ", [])
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.formatCode(nil)
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.formatting == [TextStyleRange(style: .code, start: 2, length: 1)])
    }
    @Test func listTogglesWholeLines() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("intro\none\ntwo", [])
        view.setSelectedRange(NSRange(location: 7, length: 4))  // "ne\ntw"
        view.formatList(nil)
        #expect(
            view.formatting == [
                TextStyleRange(style: .listItem, start: 6, length: 4),
                TextStyleRange(style: .listItem, start: 10, length: 3),
            ])
    }
    @Test func loadingADraftRoundTripsItsFormatting() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        let formatting = [
            TextStyleRange(style: .bold, start: 3, length: 2), TextStyleRange(style: .italic, start: 4, length: 3),
            TextStyleRange(style: .strike, start: 0, length: 2),
        ]
        view.load("😀 hi there", formatting)
        #expect(Set(view.formatting) == Set(formatting))
    }
    @Test func pasteTakesPlainTextOnly() {
        #expect(ComposerTextView(usingTextLayoutManager: false).readablePasteboardTypes == [.string])
    }
}
