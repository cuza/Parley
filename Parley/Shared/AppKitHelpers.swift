import AppKit

/// A menu item that runs a closure: menus built in code (a message's, an attachment's, the app's) need no target object.
final class ClosureMenuItem: NSMenuItem {
    let handler: () -> Void  // also VoiceOver's action of the same name (see MessageRowView.accessibilityCustomActions)
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

extension CATransaction {
    /// Runs `changes` with Core Animation's implicit animations off, so frames and colours change at once.
    static func withoutAnimation(_ changes: () -> Void) {
        begin()
        setDisableActions(true)
        changes()
        commit()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
    convenience init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(rgb: rgb)
    }
    var hex: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X", Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()))
    }
}
