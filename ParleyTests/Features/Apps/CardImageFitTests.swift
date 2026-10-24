import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyDomain

/// A card that is only a picture (and a short line over it) is as wide as the picture and the card's padding, as web
/// draws it, not spread across the message column; a card with more in it keeps the full width.
/// Serialized: every test here records picture sizes, and one points the global `CardLayout.sizesFile` at a file of its
/// own, which the others' saves would write to as well.
@MainActor @Suite(.serialized) struct CardImageFitTests {
    private func card(_ url: URL, size: CGSize, _ before: [Card.Item] = []) -> Card {
        Card(sections: [before + [.image(url, aspect: Double(size.width / size.height))]])
    }
    private func url(_ name: String) -> URL { URL(string: "https://example.com/\(name).gif")! }

    /// A picture's size outlives the launch, so its card is the right width before the picture loads again.
    @Test func pictureSizesAreKeptBetweenLaunches() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = CardLayout.sizesFile
        CardLayout.sizesFile = folder.appending(path: "sizes.plist")
        defer { CardLayout.sizesFile = saved }
        let url = url("kept-\(UUID().uuidString)")
        CardLayout.noteNatural(url, CGSize(width: 390, height: 260))
        // The file is written by a background task, which a busy Mac can hold back for a while.
        await eventually(timeout: .seconds(10)) { CardLayout.sizes(in: CardLayout.sizesFile)[url] != nil }
        #expect(CardLayout.sizes(in: CardLayout.sizesFile)[url] == CGSize(width: 390, height: 260))
        #expect(CardLayout.sizes(in: folder.appending(path: "missing.plist")).isEmpty)
    }
    @Test func aLandscapePictureHugsItsWidth() {
        let url = url("landscape")
        let size = CGSize(width: 390, height: 260)
        CardLayout.noteNatural(url, size)
        let line = Card.Item.text("Requested by @dave", [])
        let measured = CardLayout.size(card(url, size: size, [line]), maxWidth: 800)
        #expect(measured.width == 390 + 2 * CardLayout.pad)
    }
    @Test func aPortraitPictureHugsItsWidth() {
        let url = url("portrait")
        let size = CGSize(width: 260, height: 390)
        CardLayout.noteNatural(url, size)
        #expect(CardLayout.size(card(url, size: size), maxWidth: 800).width == 260 + 2 * CardLayout.pad)
    }
    @Test func aSmallPictureNeverMakesTheCardNarrowerThanTheMinimum() {
        let url = url("tiny")
        CardLayout.noteNatural(url, CGSize(width: 40, height: 40))
        #expect(
            CardLayout.size(card(url, size: CGSize(width: 40, height: 40)), maxWidth: 800).width == CardLayout.minFit)
    }
    @Test func aWidePictureStaysWithinTheCardWidth() {
        let url = url("wide")
        CardLayout.noteNatural(url, CGSize(width: 900, height: 450))
        let measured = CardLayout.size(card(url, size: CGSize(width: 900, height: 450)), maxWidth: 800)
        #expect(measured.width == RowLayout.maxBubble)
    }
    @Test func aLongLineOrARowWithAButtonKeepsTheFullWidth() {
        let url = url("withtext")
        let size = CGSize(width: 390, height: 260)
        CardLayout.noteNatural(url, size)
        let long = Card.Item.text(String(repeating: "A line of text that runs on and on. ", count: 8), [])
        #expect(CardLayout.size(card(url, size: size, [long]), maxWidth: 800).width == RowLayout.maxBubble)
        let button = Card.Item.row(
            icon: nil, round: false, label: nil, text: "Send", formatting: [],
            button: Card.Link(title: "Open", url: URL(string: "https://example.com")!))
        #expect(CardLayout.size(card(url, size: size, [button]), maxWidth: 800).width == RowLayout.maxBubble)
    }
    @Test func beforeThePictureLoadsTheCardKeepsTheFullWidth() {
        let size = CGSize(width: 390, height: 260)
        #expect(CardLayout.size(card(url("unknown"), size: size), maxWidth: 800).width == RowLayout.maxBubble)
    }

    /// Hosted at the measured size, the picture is drawn at its own size, at the card's left padding, and fills the
    /// height the layout reserved.
    @Test func theDrawnPictureMatchesTheMeasuredCard() async throws {
        let url = url("hosted")
        let size = CGSize(width: 260, height: 390)
        let red = NSImage(size: size, flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        RemoteImage.preload([(url, red)])
        CardLayout.noteNatural(url, size)
        let card = card(url, size: size, [.text("Requested by @dave", [])])
        let measured = CardLayout.size(card, maxWidth: 800)
        #expect(measured.width == 260 + 2 * CardLayout.pad)
        let host = NSHostingView(rootView: CardView(card: card))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: measured), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: measured)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var minX = Int.max
        var maxX = -1
        var minY = Int.max
        var maxY = -1
        let scale = CGFloat(rep.pixelsWide) / measured.width
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    color.redComponent - color.greenComponent > 0.4
                else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        #expect(abs(CGFloat(minX) / scale - CardLayout.pad) <= 1.5)
        #expect(abs(CGFloat(maxX + 1 - minX) / scale - 260) <= 1.5, "drawn \(CGFloat(maxX + 1 - minX) / scale) wide")
        #expect(abs(CGFloat(maxY + 1 - minY) / scale - 390) <= 1.5)
        #expect(CGFloat(maxY + 1) / scale <= measured.height + 0.5)
    }
}
