import AppKit
import SwiftUI

/// A Telegram-style chat wallpaper (Settings ▸ Wallpaper): a four-colour gradient behind the timeline.
enum Wallpaper: String, CaseIterable, Sendable {
    case none, meadow, ocean, sunset, lavender
    static let doodlesKey = "wallpaperDoodles"
    /// One per appearance, as Telegram keeps a wallpaper for its day and night themes.
    static func key(dark: Bool) -> String { dark ? "wallpaperDark" : "wallpaper" }
    static func current(dark: Bool) -> Wallpaper {
        UserDefaults.standard.string(forKey: key(dark: dark)).flatMap(Self.init) ?? .none
    }
    /// Top-left, top-right, bottom-left, bottom-right. Meadow is Telegram's default; the others mix its preset colours.
    var colors: [UInt32] {
        switch self {
        case .none: []
        case .meadow: [0xdbddbb, 0x6ba587, 0xd5d88d, 0x88b884]
        case .ocean: [0xd4dfea, 0x6ab7ea, 0xb3cde1, 0x8bd2cc]
        case .sunset: [0xffd7ae, 0xde8751, 0xffafaf, 0xffb66d]
        case .lavender: [0xd5cef7, 0x9592ed, 0xefd5e0, 0xe8bcea]
        }
    }
}

/// The gradient for the current appearance, dimmed in dark mode so light text and the dark bubbles stay readable.
struct WallpaperView: View {
    var doodles = true
    @AppStorage(Wallpaper.key(dark: false)) private var light = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var dark = Wallpaper.none
    @Environment(\.colorScheme) private var scheme
    private var wallpaper: Wallpaper { scheme == .dark ? dark : light }
    var body: some View {
        if wallpaper != .none {
            MeshGradient(
                width: 2, height: 2, points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                colors: wallpaper.colors.map {
                    Color(
                        nsColor: scheme == .dark
                            ? NSColor(rgb: $0).blended(withFraction: 0.7, of: .black)! : NSColor(rgb: $0))
                }
            )
            .overlay {
                if doodles {  // black doodles in soft light, as Telegram blends its pattern; faint light ones in dark mode
                    Image(nsImage: WallpaperPattern.tile).resizable(resizingMode: .tile)
                        .modifier(PatternLook(dark: scheme == .dark))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false).accessibilityHidden(true)  // decoration: clicks and VoiceOver reach the timeline
        }
    }
}

private struct PatternLook: ViewModifier {
    let dark: Bool
    func body(content: Content) -> some View {
        if dark { content.colorInvert().opacity(0.07) } else { content.blendMode(.softLight).opacity(0.5) }
    }
}

/// Parley's own doodle pattern over the gradient: SF Symbols outlines of mixed sizes, scattered at random and turned
/// any way, packed close without touching (dart throwing, as Telegram's doodles sit). Drawn once at launch, then tiled.
@MainActor enum WallpaperPattern {
    static let size: CGFloat = 640
    static let symbols = [
        "bubble.left", "heart", "star", "camera", "paperplane", "music.note", "cup.and.saucer", "leaf", "moon",
        "sun.max", "gift", "bell", "pencil", "book", "headphones", "gamecontroller", "airplane", "balloon",
        "cloud", "bicycle", "umbrella", "fish", "pawprint", "sparkles", "eyeglasses", "hand.thumbsup",
        "envelope", "lightbulb", "globe.americas", "puzzlepiece", "birthday.cake", "tortoise", "hare",
        "camera.macro", "theatermasks", "crown", "flame", "drop", "snowflake", "bolt", "car", "house",
        "carrot", "fork.knife", "basketball", "soccerball", "tennisball", "guitars", "paintbrush", "scissors",
        "key", "flag", "map", "tent", "mountain.2", "beach.umbrella", "sailboat", "bird", "ladybug", "ant",
        "atom", "dice", "trophy", "graduationcap", "bus", "tram", "binoculars", "cat", "dog", "teddybear",
        "popcorn", "wineglass", "mug", "cloud.rain", "rainbow", "tree", "camera.aperture", "film", "magnifyingglass",
    ]
    struct Placement: Equatable {
        var symbol: String
        var center: CGPoint
        var angle: CGFloat
        var points: CGFloat
    }
    /// Seeded, so the pattern is the same on every launch and every Mac. Distances wrap around the tile's edges, so a
    /// doodle near one edge leaves room for those across the seam, and the tiling shows no seam.
    static let placements: [Placement] = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)
        }
        let available = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
        var placed: [Placement] = []
        var pool: [String] = []
        for _ in 0..<20000 {
            let points = 16 + 22 * next() * next()  // mostly small, a few big
            let center = CGPoint(x: next() * size, y: next() * size)
            let fits = placed.allSatisfy { other in
                var dx = abs(center.x - other.center.x)
                var dy = abs(center.y - other.center.y)
                dx = min(dx, size - dx)
                dy = min(dy, size - dy)
                return (dx * dx + dy * dy).squareRoot() >= (points + other.points) * 0.62 + 2
            }
            guard fits else { continue }
            if pool.isEmpty { pool = available }
            let symbol = pool.remove(at: Int(next() * CGFloat(pool.count)) % pool.count)
            placed.append(Placement(symbol: symbol, center: center, angle: (next() - 0.5) * .pi, points: points))
        }
        return placed
    }()
    static let tile: NSImage = {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            for placement in placements {  // one near an edge is drawn again across it, where the next tile starts
                let center = placement.center
                let reach = size / 2 + placement.points
                for dx in [-size, 0, size] where abs(center.x + dx - size / 2) < reach {
                    for dy in [-size, 0, size] where abs(center.y + dy - size / 2) < reach {
                        draw(placement, at: CGPoint(x: center.x + dx, y: center.y + dy))
                    }
                }
            }
            return true
        }
    }()
    private static func draw(_ placement: Placement, at center: CGPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: placement.points, weight: .regular).applying(
            .init(paletteColors: [.black]))
        guard
            let symbol = NSImage(systemSymbolName: placement.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: center.x, yBy: center.y)
        turn.rotate(byRadians: placement.angle)
        turn.concat()
        symbol.draw(
            in: NSRect(
                x: -symbol.size.width / 2, y: -symbol.size.height / 2, width: symbol.size.width,
                height: symbol.size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}
