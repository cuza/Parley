import SwiftUI

/// The sidebar's footer: my status as a menu, as Google Chat's status button offers it (automatic, Do Not Disturb for a
/// while, away, a custom status). While not connected it shows the connection instead.
struct OwnStatusFooter: View {
    @Bindable var store: ChatStore
    @State private var pickingDNDEnd = false
    @State private var editingStatus = false
    static let dndChoices: [(title: String, duration: TimeInterval)] = [
        ("30 minutes", 30 * 60), ("1 hour", 3600), ("2 hours", 2 * 3600), ("4 hours", 4 * 3600), ("8 hours", 8 * 3600), ("24 hours", 24 * 3600),
    ]
    static func label(_ status: OwnStatus) -> String {
        switch status.availability {
        case .automatic: "Active"
        case .away: "Away"
        case .doNotDisturb(let until): "Do not disturb until \(until.formatted(Self.endFormat(until)))"
        }
    }
    /// The time alone today, with the day otherwise, as Google Chat writes "until 10:15 AM".
    private static func endFormat(_ date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
    }
    static func presence(_ status: OwnStatus) -> Presence {
        switch status.availability { case .automatic: .available; case .away: .away; case .doNotDisturb: .doNotDisturb }
    }

    var body: some View {
        HStack(spacing: 7) {
            if store.connection == .connected {
                SwiftUI.TimelineView(.everyMinute) { context in menu(store.ownStatus.current(at: context.date)) }
            } else {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text(store.connection.rawValue).font(.caption)
            }
            Spacer()
        }
        .foregroundStyle(.secondary).padding(14)
        .sheet(isPresented: $pickingDNDEnd) { DNDEndSheet(store: store) }
        .sheet(isPresented: $editingStatus) { CustomStatusSheet(store: store, current: store.ownStatus.current(at: .now).custom) }
    }

    private func menu(_ status: OwnStatus) -> some View {
        let dnd = if case .doNotDisturb = status.availability { true } else { false }
        return Menu {
            Toggle("Automatic", isOn: choice(status.availability == .automatic) { await store.setAway(false) })
            Menu(dnd ? Self.label(status) : "Do not disturb") {
                ForEach(Self.dndChoices, id: \.title) { choice in
                    Button(choice.title) { Task { await store.setDoNotDisturb(for: choice.duration) } }
                }
                Divider()
                Button("Until a specific time…") { pickingDNDEnd = true }
                if dnd { Divider(); Button("Turn off") { Task { await store.setAway(false) } } }
            }
            Toggle("Set as away", isOn: choice(status.availability == .away) { await store.setAway(true) })
            Divider()
            Button(status.custom == nil ? "Add a status…" : "Edit status…") { editingStatus = true }
            if status.custom != nil { Button("Clear status") { Task { await store.setCustomStatus(nil) } } }
        } label: {
            HStack(spacing: 6) {
                PresenceDot(presence: Self.presence(status))
                Text(Self.label(status)).lineLimit(1)
                if let custom = status.custom { Text("· \(custom.emoji) \(custom.text)").lineLimit(1).truncationMode(.tail) }
            }.font(.caption)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        .help("Your status").accessibilityLabel("Status: \(Self.label(status))")
    }
    /// A radio-like menu item: checked when chosen; choosing it again changes nothing.
    private func choice(_ selected: Bool, _ action: @escaping () async -> Void) -> Binding<Bool> {
        Binding(get: { selected }, set: { _ in if !selected { Task { await action() } } })
    }
}

/// "Do Not Disturb until a specific time": the end is sent as a duration from now, as Google Chat does.
private struct DNDEndSheet: View {
    let store: ChatStore
    @State private var end = Date.now.addingTimeInterval(3600)
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mute chat notifications until").font(.headline)
            DatePicker("Until", selection: $end, in: Date.now..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") { let duration = end.timeIntervalSinceNow; dismiss(); Task { await store.setDoNotDisturb(for: duration) } }
                    .keyboardShortcut(.defaultAction).disabled(end <= .now)
            }
        }.padding(20).frame(width: 320)
    }
}

/// "Your status": an emoji, up to 64 characters of text, and when it clears, with Google Chat's choices and presets.
private struct CustomStatusSheet: View {
    let store: ChatStore
    @State private var emoji: String
    @State private var text: String
    @State private var expiry: CustomStatusExpiry? = .today   // nil: the custom end below
    @State private var customEnd = Date.now.addingTimeInterval(3600)
    @State private var pickingEmoji = false
    @Environment(\.dismiss) private var dismiss
    static let maxLength = 64
    static let presets: [(text: String, expiry: CustomStatusExpiry)] = [
        ("Be right back", .thirtyMinutes), ("Commuting", .oneHour), ("Out sick", .today), ("Vacationing", .thisWeek),
    ]
    init(store: ChatStore, current: CustomStatus?) {
        self.store = store
        _emoji = State(initialValue: current?.emoji ?? "💭")
        _text = State(initialValue: current?.text ?? "")
        if let expires = current?.expires { _expiry = State(initialValue: nil); _customEnd = State(initialValue: expires) }
    }
    private var end: Date? { expiry.map { $0.date(from: .now) } ?? customEnd }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your status").font(.headline)
            HStack {
                Button(emoji.isEmpty ? "💭" : emoji) { pickingEmoji = true }.buttonStyle(.borderless).font(.title2)
                    .help("Choose an emoji").accessibilityLabel("Choose an emoji")
                    .popover(isPresented: $pickingEmoji) {
                        EmojiPicker(frequent: EmojiUsage().top(EmojiPicker.columns), pick: { emoji = $0; pickingEmoji = false },
                                    close: { pickingEmoji = false })
                    }
                TextField("Write your own status", text: $text).textFieldStyle(.roundedBorder)
                    .onChange(of: text) { if text.count > Self.maxLength { text = String(text.prefix(Self.maxLength)) } }
            }
            Text("\(text.count) of \(Self.maxLength) characters").font(.caption).foregroundStyle(.secondary)
            if text.isEmpty {
                ForEach(Self.presets, id: \.text) { preset in
                    Button("\(preset.text), \(preset.expiry.rawValue.lowercased())") { text = preset.text; expiry = preset.expiry }.buttonStyle(.link)
                }
            } else {
                Picker("Clear status after", selection: $expiry) {
                    ForEach(CustomStatusExpiry.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    Text("Custom…").tag(CustomStatusExpiry?.none)
                }
                if expiry == nil {
                    DatePicker("Until", selection: $customEnd, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            HStack {
                if !text.isEmpty { Button("Clear status") { text = "" } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    let status = text.isEmpty ? nil : CustomStatus(text: text, emoji: emoji.isEmpty ? "💭" : emoji, expires: end)
                    dismiss(); Task { await store.setCustomStatus(status) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360)
    }
}
