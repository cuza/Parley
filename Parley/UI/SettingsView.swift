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
        ColorPicker("Bubble color", selection: $color, supportsOpacity: false)
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
            case .notifications: NotificationsSettings(store: store)
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
                            try Giphy.setKey(key)
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
        } message: { Text("Parley forgets this Google session and the messages it keeps on this Mac. Your drafts stay.") }
    }
}

/// Settings ▸ Appearance: light or dark, wallpaper and bubble colour per appearance, message style, window tabs.
private struct AppearanceSettings: View {
    @AppStorage("timelineStyle") private var style = TimelineStyle.bubbles
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.auto
    @AppStorage(Wallpaper.key(dark: false)) private var wallpaper = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var darkWallpaper = Wallpaper.none
    @AppStorage(Wallpaper.doodlesKey) private var doodles = true
    @AppStorage(BubblePalette.colorKey(dark: false)) private var bubbleColor = ""
    @AppStorage(BubblePalette.colorKey(dark: true)) private var darkBubbleColor = ""
    @AppStorage(ConversationTabs.key) private var windowsAsTabs = true
    @AppStorage(TextSize.key) private var textScale = 1.0   // follows View ▸ Bigger and Smaller too
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
                    .help("Use the accent color").accessibilityLabel("Use the accent color")
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
            Section {
                // One stop per step of View ▸ Bigger and Smaller, as Messages' text size slider.
                Slider(value: Binding(get: { Double(TextSize.steps.firstIndex(of: TextSize.next(from: textScale, by: 0)) ?? 1) },
                                      set: { TextSize.set(TextSize.steps[Int($0.rounded())]) }),
                       in: 0...Double(TextSize.steps.count - 1), step: 1) {
                    Text("Text size")
                } minimumValueLabel: {
                    Text("A").font(.caption).accessibilityLabel("Smaller")
                } maximumValueLabel: {
                    Text("A").font(.title2).accessibilityLabel("Bigger")
                }
            } footer: {
                Footer("View ▸ Bigger (⌘+) and Smaller (⌘−) change it too.")
            }
            Section {
                Toggle("Open conversation windows as tabs", isOn: $windowsAsTabs)
            } header: { Text("Windows") } footer: {
                Footer("A conversation opened in a new window joins the conversation window already open as a tab. Window ▸ Merge All Windows joins them either way.")
            }
        }
    }
}

/// "Open Parley at login", read from macOS each time Settings shows it, since it can change in System Settings too.
private struct LoginItemSection: View {
    @AppStorage(LaunchLanding.key) private var landing = LaunchLanding.home
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
            Picker("At launch, open", selection: $landing) {
                Text("Home").tag(LaunchLanding.home)
                Text("The last conversation").tag(LaunchLanding.last)
            }
        } footer: {
            if let failure { Footer(failure, color: .red) }
        }
        .onAppear(perform: read)
    }
    private func read() { on = item.isOn || item.needsApproval; needsApproval = item.needsApproval }
}

/// Settings ▸ Notifications: on or off, the sound, and the account's do not disturb schedule.
private struct NotificationsSettings: View {
    let store: ChatStore
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
            DndScheduleSection(store: store)
        }
    }
}

/// The do not disturb schedule, as web Chat's settings list it: each period with its own switch, Edit, and Add.
private struct DndScheduleSection: View {
    let store: ChatStore
    @State private var editing: Int?   // an index into the periods; the count adds one
    var body: some View {
        Section {
            if let schedules = store.dndSchedules {
                ForEach(schedules.periods.indices, id: \.self) { index in
                    let period = schedules.periods[index]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DndScheduleEditor.times(period))
                            Text(period.dayList()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = index }
                        Toggle(DndScheduleEditor.times(period), isOn: Binding(get: { period.enabled }, set: { on in
                            var changed = schedules; changed.periods[index].enabled = on
                            Task { await store.saveDndSchedules(changed) }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                }
                Button("Add Schedule…") { editing = schedules.periods.count }.disabled(schedules.periods.count >= DndSchedules.limit)
                Toggle("Follow the Mac's time zone", isOn: Binding(get: { schedules.followsTimeZone }, set: { on in
                    var changed = schedules; changed.followsTimeZone = on
                    Task { await store.saveDndSchedules(changed) }
                }))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        } header: {
            Text("Do not disturb schedule")
        } footer: {
            let zone = (TimeZone(identifier: store.dndSchedules?.timeZone ?? "") ?? .current).localizedName(for: .generic, locale: .current)
            Footer("Do not disturb turns on by itself at these times, in Parley, on the web and on your phone. Times are in \(zone ?? "your time zone").")
        }
        .task { if store.dndSchedules == nil { await store.loadDndSchedules() } }
        .sheet(item: Binding(get: { editing.map(EditingIndex.init) }, set: { editing = $0?.index })) { item in
            if let schedules = store.dndSchedules {
                DndScheduleEditor(period: item.index < schedules.periods.count ? schedules.periods[item.index] : nil) { result in
                    editing = nil
                    var changed = schedules
                    switch result {
                    case .save(let period) where item.index < changed.periods.count: changed.periods[item.index] = period
                    case .save(let period): changed.periods.append(period)
                    case .delete: changed.periods.remove(at: item.index)
                    case .cancel: return
                    }
                    Task { await store.saveDndSchedules(changed) }
                }
            }
        }
    }
    private struct EditingIndex: Identifiable { let index: Int; var id: Int { index } }
}

/// One do not disturb period: its times, or all day, and its days.
struct DndScheduleEditor: View {
    enum Result { case save(DndSchedules.Period), delete, cancel }
    let isNew: Bool
    let done: (Result) -> Void
    @State private var period: DndSchedules.Period
    init(period: DndSchedules.Period?, done: @escaping (Result) -> Void) {
        isNew = period == nil
        self.done = done
        // A new one starts as web Chat's: weeknights, 6 PM to 9 AM.
        _period = State(initialValue: period ?? .init(days: [1, 2, 3, 4, 5], start: 18 * 60, end: 9 * 60))
    }
    /// "7:00 PM – 7:00 AM", or "All day".
    static func times(_ period: DndSchedules.Period) -> String {
        period.isAllDay ? "All day" : "\(clock(period.start)) – \(clock(period.end))"
    }
    private static func clock(_ minutes: Int) -> String { date(minutes).formatted(date: .omitted, time: .shortened) }
    private static func date(_ minutes: Int) -> Date { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now }
    private static func minutes(_ date: Date) -> Int { let c = Calendar.current.dateComponents([.hour, .minute], from: date); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }
    private func time(_ keyPath: WritableKeyPath<DndSchedules.Period, Int>) -> Binding<Date> {
        Binding(get: { Self.date(period[keyPath: keyPath]) }, set: { period[keyPath: keyPath] = Self.minutes($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Schedule" : "Edit Schedule").font(.headline)
            Toggle("All day", isOn: Binding(get: { period.isAllDay }, set: { allDay in
                if allDay { period.start = 0; period.end = 0 } else { period.start = 18 * 60; period.end = 9 * 60 }
            }))
            if !period.isAllDay {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("From").gridColumnAlignment(.trailing)
                        DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute).labelsHidden()
                    }
                    GridRow {
                        Text("To")
                        DatePicker("To", selection: time(\.end), displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
            }
            HStack(spacing: 4) {   // the week in the order it starts here
                let calendar = Calendar.current
                ForEach((0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }, id: \.self) { index in
                    let day = index == 0 ? 7 : index
                    Toggle(calendar.veryShortWeekdaySymbols[index], isOn: Binding(get: { period.days.contains(day) }, set: { on in
                        if on { period.days.append(day) } else { period.days.removeAll { $0 == day } }
                    }))
                    .toggleStyle(.button).help(calendar.weekdaySymbols[index])
                }
            }
            HStack {
                if !isNew { Button("Delete", role: .destructive) { done(.delete) } }
                Spacer()
                Button("Cancel", role: .cancel) { done(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Save") { done(.save(period)) }.keyboardShortcut(.defaultAction).disabled(period.days.isEmpty)
            }
        }
        .padding(20).frame(width: 320)
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
