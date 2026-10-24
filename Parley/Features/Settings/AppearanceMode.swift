import AppKit

/// Settings ▸ Appearance: follow macOS, or keep Parley light or dark.
enum AppearanceMode: String, CaseIterable {
    case auto, light, dark
    static let key = "appearance"
    @MainActor static func apply() {
        let mode = UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .auto
        NSApplication.shared.appearance = mode == .auto ? nil : NSAppearance(named: mode == .light ? .aqua : .darkAqua)
    }
}
