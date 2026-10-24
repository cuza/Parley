import SwiftUI

/// The tabs of Parley ▸ Settings, the last one shown remembered.
enum SettingsTab: String, CaseIterable {
    case general, appearance, notifications, advanced
    static let key = "settingsTab"
    /// Every tab's width: the window keeps it and takes each tab's height, as macOS settings windows do.
    static let width: CGFloat = 520
}

/// Parley ▸ Settings (⌘,): one tab per topic.
struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general
    var body: some View {
        TabView(selection: $tab) {
            Self.page(.general).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            Self.page(.appearance).tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(
                SettingsTab.appearance)
            Self.page(.notifications).tabItem { Label("Notifications", systemImage: "bell.badge") }.tag(
                SettingsTab.notifications)
            Self.page(.advanced).tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag(SettingsTab.advanced)
        }
    }
    /// One tab's content at the settings width: a grouped form, as System Settings draws its panes.
    static func page(_ tab: SettingsTab) -> some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            case .notifications: NotificationsSettings()
            case .advanced: AdvancedSettings()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true).fixedSize(horizontal: false, vertical: true)  // the window takes the tab's height
        .frame(width: SettingsTab.width)
    }
}

/// A section footer: a short caption the form wraps inside its margins.
struct SettingsFooter: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
