import ParleyDomain
import SwiftUI
import UserNotifications

/// Settings ▸ Notifications: on or off, the sound, and the account's do not disturb schedule.
struct NotificationsSettings: View {
    @AppStorage(NotificationSettings.enabledKey) private var notify = true
    @AppStorage(NotificationSound.key) private var sound = NotificationSound.standard.stored
    @AppStorage(NotificationSettings.bounceKey) private var bounce = false
    @State private var sounds = NotificationSound.available()
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined
    @MainActor private static var playing: NSSound?
    private static func play(_ sound: NotificationSound) {
        playing?.stop()  // one at a time, as System Settings plays them
        playing = sound.preview
        playing?.play()
    }
    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $notify)
                    .onChange(of: notify) { _, on in
                        if on { Task { notificationStatus = await NotificationSettings.requestAuthorization() } }
                    }
                    .task {
                        notificationStatus = await UNUserNotificationCenter.current().notificationSettings()
                            .authorizationStatus
                    }
                if notify, notificationStatus == .denied {
                    LabeledContent {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    } label: {
                        Text("macOS isn't letting Parley show notifications.").foregroundStyle(.orange)
                    }
                }
            } footer: {
                SettingsFooter(
                    "Each conversation notifies as set in its Notifications menu, as in web and mobile Chat. Muted conversations never notify."
                )
            }
            Section {
                // As System Settings ▸ Sound offers its alert sound: the Mac's sounds, the choice played, a button to hear it again.
                LabeledContent("Sound") {
                    HStack {
                        Picker("Sound", selection: $sound) {
                            ForEach(sounds, id: \.self) { Text($0.name).tag($0.stored) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: sound) { _, sound in Self.play(NotificationSound(stored: sound)) }
                        Button {
                            Self.play(NotificationSound(stored: sound))
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless).help("Play the sound").accessibilityLabel("Play the sound")
                        .disabled(NotificationSound(stored: sound).preview == nil)
                    }
                }
                .disabled(!notify)
            } footer: {
                SettingsFooter(
                    (NotificationSound(stored: sound).playedByParley
                        ? "Parley plays this sound itself, even during Focus. macOS would play only its default sound."
                        : "macOS plays its default sound and follows your Focus settings.")
                        + " Banners and sounds are also set in System Settings ▸ Notifications.")
            }
            Section {
                Toggle("Bounce the Dock icon", isOn: $bounce).disabled(!notify)
            } footer: {
                SettingsFooter("Once for each notification, while Parley is in the background.")
            }
            DndScheduleSection()
        }
    }
}

/// The do not disturb schedule, as web Chat's settings list it: each period with its own switch, Edit, and Add.
private struct DndScheduleSection: View {
    @Environment(ChatStore.self) private var store
    @State private var editing: Int?  // an index into the periods; the count adds one
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
                        Toggle(
                            DndScheduleEditor.times(period),
                            isOn: Binding(
                                get: { period.enabled },
                                set: { on in
                                    var changed = schedules
                                    changed.periods[index].enabled = on
                                    Task { await store.saveDndSchedules(changed) }
                                })
                        ).labelsHidden().toggleStyle(.switch)
                    }
                }
                Button("Add Schedule…") { editing = schedules.periods.count }.disabled(
                    schedules.periods.count >= DndSchedules.limit)
                Toggle(
                    "Follow the Mac's time zone",
                    isOn: Binding(
                        get: { schedules.followsTimeZone },
                        set: { on in
                            var changed = schedules
                            changed.followsTimeZone = on
                            Task { await store.saveDndSchedules(changed) }
                        }))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        } header: {
            Text("Do not disturb schedule")
        } footer: {
            let zone = (TimeZone(identifier: store.dndSchedules?.timeZone ?? "") ?? .current).localizedName(
                for: .generic, locale: .current)
            SettingsFooter(
                "Do not disturb turns on by itself at these times, in Parley, on the web and on your phone. Times are in \(zone ?? "your time zone")."
            )
        }
        .task { if store.dndSchedules == nil { await store.loadDndSchedules() } }
        .sheet(item: Binding(get: { editing.map(EditingIndex.init) }, set: { editing = $0?.index })) { item in
            if let schedules = store.dndSchedules {
                DndScheduleEditor(period: item.index < schedules.periods.count ? schedules.periods[item.index] : nil) {
                    result in
                    editing = nil
                    var changed = schedules
                    switch result {
                    case .save(let period) where item.index < changed.periods.count:
                        changed.periods[item.index] = period
                    case .save(let period): changed.periods.append(period)
                    case .delete: changed.periods.remove(at: item.index)
                    case .cancel: return
                    }
                    Task { await store.saveDndSchedules(changed) }
                }
            }
        }
    }
    private struct EditingIndex: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

/// One do not disturb period: its times, or all day, and its days.
struct DndScheduleEditor: View {
    enum Result {
        case save(DndSchedules.Period)
        case delete, cancel
    }
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
    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }
    private static func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    private func time(_ keyPath: WritableKeyPath<DndSchedules.Period, Int>) -> Binding<Date> {
        Binding(get: { Self.date(period[keyPath: keyPath]) }, set: { period[keyPath: keyPath] = Self.minutes($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Schedule" : "Edit Schedule").font(.headline)
            Toggle(
                "All day",
                isOn: Binding(
                    get: { period.isAllDay },
                    set: { allDay in
                        if allDay {
                            period.start = 0
                            period.end = 0
                        } else {
                            period.start = 18 * 60
                            period.end = 9 * 60
                        }
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
            HStack(spacing: 4) {  // the week in the order it starts here
                let calendar = Calendar.current
                ForEach((0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }, id: \.self) { index in
                    let day = index == 0 ? 7 : index
                    Toggle(
                        calendar.veryShortWeekdaySymbols[index],
                        isOn: Binding(
                            get: { period.days.contains(day) },
                            set: { on in
                                if on { period.days.append(day) } else { period.days.removeAll { $0 == day } }
                            })
                    )
                    .toggleStyle(.button).help(calendar.weekdaySymbols[index])
                }
            }
        }
        .padding(20).frame(width: 320)
        .sheetButtons(
            "Save", enabled: !period.days.isEmpty, cancel: { done(.cancel) }, confirm: { done(.save(period)) }
        )
        .toolbar {
            if !isNew {
                ToolbarItem(placement: .destructiveAction) { Button("Delete", role: .destructive) { done(.delete) } }
            }
        }
    }
}
