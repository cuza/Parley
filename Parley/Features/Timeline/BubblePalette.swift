import AppKit

/// Bubble colours: mine in the accent colour or the one chosen in Settings, with white or black text, whichever reads
/// on it; others' grey, or white (dark grey in dark mode) on a wallpaper, as Telegram draws them.
enum BubblePalette {
    /// "#RRGGBB" per appearance, as Telegram keeps a colour for its day and night themes; unset: the accent colour.
    static func colorKey(dark: Bool) -> String { dark ? "bubbleColorDark" : "bubbleColor" }
    static func own(dark: Bool) -> NSColor {
        UserDefaults.standard.string(forKey: colorKey(dark: dark)).flatMap(NSColor.init(hex:)) ?? .controlAccentColor
    }
    // Dynamic: each resolves for the appearance it is drawn in, so switching light and dark swaps the settings too.
    static let own = NSColor(name: nil) { resolved(own(dark: $0.isDark), in: $0) }
    /// Text and icons on my bubble.
    static let ownInk = NSColor(name: nil) { ink(on: resolved(own(dark: $0.isDark), in: $0)) }
    /// Quotes, times and links on my bubble.
    static let ownAccent = NSColor(name: nil) { accent(on: resolved(own(dark: $0.isDark), in: $0)) }
    /// On a pale fill, a deeper shade of it, as Telegram derives its outgoing accents from a picked bubble colour
    /// (hue ×1.008, saturation ×5.01, brightness ×0.549, 80% opaque); white on a fill that takes white text.
    static func accent(on fill: NSColor) -> NSColor {
        guard ink(on: fill) == .black, let srgb = fill.usingColorSpace(.sRGB) else { return .white }
        func clamped(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
        return NSColor(
            colorSpace: .sRGB, hue: clamped(srgb.hueComponent * 1.008),
            saturation: clamped(srgb.saturationComponent * 5.0094),
            brightness: clamped(srgb.brightnessComponent * 0.549), alpha: 0.8)
    }
    /// A chip or card on my bubble: a shade darker under white text, lighter under black.
    static let ownWell = NSColor(name: nil) {
        ink(on: resolved(own(dark: $0.isDark), in: $0)) == .white
            ? .black.withAlphaComponent(0.22) : .white.withAlphaComponent(0.45)
    }
    static let incoming = NSColor(name: nil) {
        Wallpaper.current(dark: $0.isDark) == .none
            ? resolved(.unemphasizedSelectedContentBackgroundColor, in: $0)
            : $0.isDark ? NSColor(rgb: 0x3d414d) : .white
    }
    /// Date headers and service lines: white on a tinted pill over a wallpaper, as Telegram draws them; else plain grey.
    static let serviceText = NSColor(name: nil) {
        Wallpaper.current(dark: $0.isDark) == .none ? resolved(.secondaryLabelColor, in: $0) : .white
    }
    static let servicePill = NSColor(name: nil) {
        Wallpaper.current(dark: $0.isDark) == .none ? .clear : .black.withAlphaComponent($0.isDark ? 0.5 : 0.25)
    }
    /// The time beside large emoji: the service pill over a wallpaper, a faint one without.
    static let timePill = NSColor(name: nil) {
        Wallpaper.current(dark: $0.isDark) == .none
            ? resolved(.labelColor.withAlphaComponent(0.06), in: $0) : .black.withAlphaComponent($0.isDark ? 0.5 : 0.25)
    }
    /// The time over a picture: white on the picture blurred and darkened (Telegram's: black 25% light, 50% dark).
    static let mediaPill = NSColor(name: nil) { .black.withAlphaComponent($0.isDark ? 0.5 : 0.25) }
    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
        return result
    }
    // ponytail: a luminance cut, not a contrast ratio; WCAG's ratio prefers black even on Apple's blue.
    /// Black once the fill's relative luminance passes 0.45: white stays on Apple's blue, green and orange, as Messages
    /// draws them, and black goes on yellow and pale fills.
    static func ink(on fill: NSColor) -> NSColor {
        guard let srgb = fill.usingColorSpace(.sRGB) else { return .white }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance =
            0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent) + 0.0722
            * linear(srgb.blueComponent)
        return luminance > 0.45 ? .black : .white
    }
}
