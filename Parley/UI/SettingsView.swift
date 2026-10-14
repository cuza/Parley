import ServiceManagement
import UserNotifications
import SwiftUI

/// macOS's login item for an app; `SMAppService.mainApp` in the app, a fake in tests.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}
extension SMAppService: LoginItemService {}
/// Settings ▸ General's "Open Parley at login". Off until turned on: macOS registers nothing by itself.
struct LoginItem {
    var service: LoginItemService = SMAppService.mainApp
    var isOn: Bool { service.status == .enabled }
    /// Turned on, waiting for the user in System Settings ▸ General ▸ Login Items.
    var needsApproval: Bool { service.status == .requiresApproval }
    func set(_ on: Bool) throws { if on { try service.register() } else { try service.unregister() } }
}

/// Settings ▸ Appearance: follow macOS, or keep Parley light or dark.
enum AppearanceMode: String, CaseIterable {
    case auto, light, dark
    static let key = "appearance"
    @MainActor static func apply() {
        let mode = UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .auto
        NSApplication.shared.appearance = mode == .auto ? nil : NSAppearance(named: mode == .light ? .aqua : .darkAqua)
    }
}

/// The colour well for one appearance's bubbles. It holds its own colour: bound straight to the stored hex, the panel's
/// Display P3 colour never matched the sRGB read back, so each answer re-saved it and the panel never settled.
struct BubbleColorPicker: View {
    @Binding var hex: String
    @State private var color: Color
    init(hex: Binding<String>) {
        _hex = hex
        _color = State(initialValue: Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .controlAccentColor))
    }
    var body: some View {
        ColorPicker("Bubble colour", selection: $color, supportsOpacity: false)
            .labelsHidden().help("Your bubbles")
            .task(id: color) {   // saved once the colour stops moving, so a drag doesn't redraw every row on every step
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let change = Self.change(from: hex, to: color) else { return }
                hex = change
            }
            .onChange(of: hex) { if Self.change(from: hex, to: color) != nil { color = Color(nsColor: NSColor(hex: hex) ?? .controlAccentColor) } }
    }
    /// The hex to save for `picked`, or nil when it rounds to the one already stored.
    static func change(from stored: String, to picked: Color) -> String? {
        guard let hex = NSColor(picked).hex, hex != stored else { return nil }
        return hex
    }
}

/// The tabs of Parley ▸ Settings, the last one shown remembered.
enum SettingsTab: String, CaseIterable {
    case general, appearance, notifications, advanced
    static let key = "settingsTab"
    /// Every tab's width: the window keeps it and takes each tab's height, as macOS settings windows do.
    static let width: CGFloat = 520
}

/// Parley ▸ Settings (⌘,): one tab per topic.
struct SettingsView: View {
    let store: ChatStore
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general
    var body: some View {
        TabView(selection: $tab) {
            Self.page(.general, store: store).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            Self.page(.appearance, store: store).tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
            Self.page(.notifications, store: store).tabItem { Label("Notifications", systemImage: "bell.badge") }.tag(SettingsTab.notifications)
            Self.page(.advanced, store: store).tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag(SettingsTab.advanced)
        }
    }
    /// One tab's content at the settings width: a grouped form, as System Settings draws its panes.
    static func page(_ tab: SettingsTab, store: ChatStore) -> some View {
        Group {
            switch tab {
            case .general: GeneralSettings(store: store)
            case .appearance: AppearanceSettings()
            case .notifications: NotificationsSettings()
            case .advanced: AdvancedSettings(store: store)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true).fixedSize(horizontal: false, vertical: true)   // the window takes the tab's height
        .frame(width: SettingsTab.width)
    }
}

/// A section footer: a short caption the form wraps inside its margins.
private struct Footer: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) { self.text = text; self.color = color }
    var body: some View { Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true) }
}

/// Settings ▸ General: account, sidebar, hidden conversations, GIPHY key.
private struct GeneralSettings: View {
    let store: ChatStore
    @Environment(SignInFlow.self) private var signIn: SignInFlow?
    @State private var confirmSignOut = false
    @State private var accountError: String?
    @State private var giphyKey = Giphy.key ?? ""
    @State private var keyError: String?
    @AppStorage(SidebarLimit.enabledKey) private var limitSections = false
    @AppStorage(SidebarLimit.countKey) private var sectionLimit = 10
    var body: some View {
        Form {
            Section {
                if store.me.id.isEmpty {
                    Text("Not signed in").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Avatar(name: store.me.name, size: 36, url: store.me.avatarURL)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.me.name).font(.headline)
                            if let email = store.me.email { Text(email).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Sign Out…") { confirmSignOut = true }.disabled(signIn == nil)
                    }
                }
            } header: { Text("Account") } footer: {
                if let accountError { Footer(accountError, color: .red) }
            }
            LoginItemSection()
            Section {
                Toggle("Limit sections", isOn: $limitSections)
                Picker("Rows per section", selection: $sectionLimit) {
                    ForEach(SidebarLimit.choices, id: \.self) { Text("\($0) rows").tag($0) }
                }
                .disabled(!limitSections)
            } header: { Text("Sidebar") } footer: {
                Footer("As in web Chat, each section shows its first rows, then Show all. Unread conversations and the open one always show.")
            }
            HiddenConversationsSection(store: store)
            Section {
                SecureField("GIPHY API key", text: $giphyKey)
                    .onChange(of: giphyKey) { _, key in
                        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try Giphy.keyItem.set(key)
                            keyError = nil
                        } catch { keyError = error.localizedDescription }
                    }
            } footer: {
                Footer(keyError ?? "For the composer's GIF picker. Create one at developers.giphy.com. Parley keeps it in your Keychain.",
                       color: keyError == nil ? .secondary : .red)
            }
        }
        .confirmationDialog("Sign out of Google Chat?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    do {
                        try await signIn?.signOut()
                        store.signedOut()
                        accountError = nil
                    } catch { accountError = error.localizedDescription }
                }
            }
        } message: { Text("Parley forgets this Google session. Your drafts stay on this Mac.") }
    }
}

/// Settings ▸ Appearance: light or dark, wallpaper and bubble colour per appearance, message style.
private struct AppearanceSettings: View {
    @AppStorage("timelineStyle") private var style = TimelineStyle.bubbles
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.auto
    @AppStorage(Wallpaper.key(dark: false)) private var wallpaper = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var darkWallpaper = Wallpaper.none
    @AppStorage(Wallpaper.doodlesKey) private var doodles = true
    @AppStorage(BubblePalette.colorKey(dark: false)) private var bubbleColor = ""
    @AppStorage(BubblePalette.colorKey(dark: true)) private var darkBubbleColor = ""
    /// One appearance's wallpaper and bubble colour.
    private func look(_ title: String, wallpaper: Binding<Wallpaper>, bubble: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Picker("Wallpaper", selection: wallpaper) {
                    ForEach(Wallpaper.allCases, id: \.self) { Text($0 == .none ? "No Wallpaper" : $0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().fixedSize()
                BubbleColorPicker(hex: bubble)
                Button("Reset") { bubble.wrappedValue = "" }.disabled(bubble.wrappedValue.isEmpty)
                    .help("Use the accent colour").accessibilityLabel("Use the accent colour")
            }
        }
    }
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Auto").tag(AppearanceMode.auto)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { AppearanceMode.apply() }
            }
            Section {
                look("Light mode", wallpaper: $wallpaper, bubble: $bubbleColor)
                look("Dark mode", wallpaper: $darkWallpaper, bubble: $darkBubbleColor)
                Toggle("Doodles over the wallpaper", isOn: $doodles).disabled(wallpaper == .none && darkWallpaper == .none)
            } header: { Text("Wallpaper and bubbles") } footer: {
                Footer("Text on your bubbles turns white or black, whichever reads better on the colour.")
            }
            Section {
                Picker("Message style", selection: $style) {
                    Text("Bubbles").tag(TimelineStyle.bubbles)
                    Text("Plain").tag(TimelineStyle.plain)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Footer("Plain lists every message on the left with names and avatars, like Telegram's list mode.")
            }
        }
    }
}

/// "Open Parley at login", read from macOS each time Settings shows it, since it can change in System Settings too.
private struct LoginItemSection: View {
    @State private var on = false
    @State private var needsApproval = false
    @State private var failure: String?
    private let item = LoginItem()
    var body: some View {
        Section {
            Toggle("Open Parley at login", isOn: $on)
                .onChange(of: on) { _, on in
                    guard on != item.isOn else { return }
                    do { try item.set(on); failure = nil } catch { failure = error.localizedDescription }
                    read()
                }
            if needsApproval {
                LabeledContent {
                    Button("Open Login Items") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                } label: { Text("macOS needs your approval in Login Items.").foregroundStyle(.orange) }
            }
        } footer: {
            if let failure { Footer(failure, color: .red) }
        }
        .onAppear(perform: read)
    }
    private func read() { on = item.isOn || item.needsApproval; needsApproval = item.needsApproval }
}

/// Settings ▸ Notifications: on or off, and the sound.
private struct NotificationsSettings: View {
    @AppStorage(NotificationSettings.enabledKey) private var notify = true
    @AppStorage(NotificationSound.key) private var sound = NotificationSound.standard.stored
    @AppStorage(NotificationSettings.bounceKey) private var bounce = false
    @State private var sounds = NotificationSound.available()
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined
    @MainActor private static var playing: NSSound?
    private static func play(_ sound: NotificationSound) {
        playing?.stop()   // one at a time, as System Settings plays them
        playing = sound.preview
        playing?.play()
    }
    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { Task { notificationStatus = await SystemNotifier.requestAuthorization() } } }
                    .task { notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
                if notify, notificationStatus == .denied {
                    LabeledContent {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    } label: { Text("macOS isn't letting Parley show notifications.").foregroundStyle(.orange) }
                }
            } footer: {
                Footer("Each conversation notifies as set in its Notifications menu, as in web and mobile Chat. Muted conversations never notify.")
            }
            Section {
                // As System Settings ▸ Sound offers its alert sound: the Mac's sounds, the choice played, a button to hear it again.
                LabeledContent("Sound") {
                    HStack {
                        Picker("Sound", selection: $sound) { ForEach(sounds, id: \.self) { Text($0.name).tag($0.stored) } }
                            .labelsHidden().fixedSize()
                            .onChange(of: sound) { _, sound in Self.play(NotificationSound(stored: sound)) }
                        Button { Self.play(NotificationSound(stored: sound)) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless).help("Play the sound").accessibilityLabel("Play the sound")
                            .disabled(NotificationSound(stored: sound).preview == nil)
                    }
                }
                .disabled(!notify)
            } footer: {
                Footer((NotificationSound(stored: sound).playedByParley
                        ? "Parley plays this sound itself, even during Focus. macOS would play only its default sound."
                        : "macOS plays its default sound and follows your Focus settings.")
                       + " Banners and sounds are also set in System Settings ▸ Notifications.")
            }
            Section {
                Toggle("Bounce the Dock icon", isOn: $bounce).disabled(!notify)
            } footer: {
                Footer("Once for each notification, while Parley is in the background.")
            }
        }
    }
}

/// Settings ▸ Advanced: connection diagnostics, the unsupported-content report, and who I blocked.
private struct AdvancedSettings: View {
    let store: ChatStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        // ponytail: the count is read when Settings draws; it doesn't follow new messages while it is open.
        let kinds = MessageShapes.shared.withLock { $0.entries.count }
        Form {
            BlockedSection(store: store)
            Section {
                LabeledContent("Connection") {
                    Button("Connection Diagnostics…") { openWindow(id: "connection-diagnostics") }
                }
            } footer: {
                Footer("Shows the connection, the saved session and read checks, with a report to copy.")
            }
            Section {
                LabeledContent("Unsupported content") {
                    HStack {
                        Button("Export…") { MessageShapes.saveExport() }
                        Button("Copy Summary") { MessageShapes.copySummary() }
                    }.disabled(kinds == 0)
                }
            } footer: {
                Footer("\(kinds) kind\(kinds == 1 ? "" : "s") seen this session. The report lists message content Parley can't draw yet, by field number only, with no text, names or ids.")
            }
        }
    }
}
