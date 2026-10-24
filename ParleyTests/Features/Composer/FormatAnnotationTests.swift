import AppKit
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Underline, text colour, code blocks, quotes and links, sent as Google Chat's web composer sends them.
struct FormatAnnotationTests {
    @Test func colourIsFontColorWithItsARGBValue() throws {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .color(TextColor.red.argb), start: 0, length: 3)])
        let one = try #require(sent.first)
        #expect(sent.count == 1 && one.type == .formatData && one.formatMetadata.formatType == .fontColor)
        #expect(one.formatMetadata.fontColor == 0xFFF4_4336 && one.startIndex == 0 && one.length == 3)
        #expect(TextColor.allCases.map(\.argb) == [0xFFF4_4336, 0xFF21_96F3, 0xFF4C_AF50, 0xFFFF_C107, 0xFF9E_9E9E])
    }
    @Test func blocksAndUnderlineKeepTheirTypes() {
        let sent = DynamiteMapper.annotations([
            TextStyleRange(style: .underline, start: 0, length: 1),
            TextStyleRange(style: .codeBlock, start: 2, length: 6),
            TextStyleRange(style: .quote, start: 8, length: 6),
        ])
        #expect(sent.map(\.formatMetadata.formatType) == [.underline, .monospaceBlock, .quoteBlock])
        #expect(sent.map(\.length) == [1, 6, 6])
    }
    @Test func aLinkIsARichTextURLOverItsText() throws {
        let sent = DynamiteMapper.annotations([
            TextStyleRange(style: .link(URL(string: "https://example.com/a")!), start: 4, length: 4)
        ])
        let link = try #require(sent.first)
        #expect(link.type == .url && link.startIndex == 4 && link.length == 4 && link.chipRenderType == .render)
        #expect(
            link.urlMetadata.url.url == "https://example.com/a" && link.urlMetadata.urlSource == .richText
                && link.urlMetadata.hasShouldNotRender && !link.urlMetadata.shouldNotRender)
    }
    @Test func theLinkFormTakesAddressesAsTyped() {
        #expect(LinkForm.url("example.com/a") == URL(string: "https://example.com/a"))
        #expect(LinkForm.url(" http://a.b ") == URL(string: "http://a.b"))
        #expect(LinkForm.url("mailto:a@b.c") == URL(string: "mailto:a@b.c"))
        #expect(LinkForm.url("") == nil && LinkForm.url("two words") == nil)
    }
    @Test func aReceivedColourShowsAsIs() throws {
        let annotation = Dynamite_Annotation.with { built in
            built.type = .formatData
            built.startIndex = 0
            built.length = 2
            built.formatMetadata = .with {
                $0.formatType = .fontColor
                $0.fontColor = 0xFF12_3456
            }
        }
        let shown = DynamiteMapper.richText("hi there", [annotation])
        #expect(shown.formatting == [TextStyleRange(style: .color(0xFF12_3456), start: 0, length: 2)])
        let styled = MessageTextStyle.styled(shown.text, shown.formatting, own: false)
        let colour = try #require(styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(
            colour.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.06
                && colour.usingColorSpace(.sRGB)?.redComponent ?? 1 < 0.08)
    }
}
