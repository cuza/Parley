import SwiftUI

/// Scheduled send's times and words, as Google Chat offers them.
enum ScheduledSend {
    /// Web's quick choices: tomorrow at 8:00 and at 13:00, and next Monday at 8:00.
    static func quickTimes(from now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let at = { (day: Date, hour: Int) in calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)! }
        let monday = calendar.nextDate(after: tomorrow, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? tomorrow
        return [at(tomorrow, 8), at(tomorrow, 13), at(monday, 8)]
    }
    /// "Tomorrow at 8:00 AM", "Monday at 8:00 AM", "Oct 30 at 8:00 AM"; inside a sentence, "tomorrow at 8:00 AM".
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current, inSentence: Bool = false) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let day = switch days {
        case 0: inSentence ? "today" : "Today"
        case 1: inSentence ? "tomorrow" : "Tomorrow"
        case 2..<7: date.formatted(.dateTime.weekday(.wide))
        default: date.formatted(.dateTime.month(.abbreviated).day())
        }
        return "\(day) at \(time)"
    }
}

/// The Send button's right-click menu: web's quick times, and any time from a sheet.
struct ScheduleMenu: View {
    var enabled: Bool
    var pick: (Date) -> Void
    var custom: () -> Void
    var body: some View {
        Section("Schedule Send") {
            ForEach(ScheduledSend.quickTimes(), id: \.self) { date in
                Button(ScheduledSend.when(date)) { pick(date) }
            }
            Button("Choose Date and Time…", action: custom)
        }.disabled(!enabled)
    }
}

/// A date and time to send at, or to move a scheduled message to; only later times can be picked.
struct ScheduleSheet: View {
    var title: String
    var start: Date
    var done: (Date?) -> Void
    @State private var date: Date
    init(title: String, start: Date = ScheduledSend.quickTimes()[0], done: @escaping (Date?) -> Void) {
        self.title = title; self.start = start; self.done = done
        _date = State(initialValue: start)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            DatePicker("Date", selection: $date, in: Date.now..., displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            DatePicker("Time", selection: $date, in: Date.now..., displayedComponents: .hourAndMinute)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Schedule") { done(date) }.keyboardShortcut(.defaultAction).disabled(date <= .now)
            }
        }
        .padding(20).frame(width: 300)
    }
}

/// A scheduled message in the Drafts shortcut, laid out as a draft's row: where it goes, when, and what it says. A click
/// opens the conversation; hovering puts web's Send now, Reschedule and Delete where the time was.
struct ScheduledRow: View {
    @Bindable var store: ChatStore
    var message: ServerDraft
    @State private var picking = false
    @State private var hovering = false
    var body: some View {
        let room = store.conversations.first { $0.id == message.conversationID }
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: room?.name ?? "", space: room?.kind == .space, size: 32, url: room?.avatarURL, emoji: room?.emoji)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(room?.name ?? "Conversation").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if message.threadID != nil { Text("· Thread").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize() }
                    Spacer(minLength: 8)
                    if hovering { buttons } else { time }
                }
                Text(TextStyleRange.plain(message.text, message.formatting)).font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .listRowSeparator(.hidden)   // as the drafts' rows
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: "Send Now") { Task { await store.sendNow(message) } }
        .accessibilityAction(named: "Reschedule") { picking = true }
        .accessibilityAction(named: "Delete") { Task { await store.unschedule(message) } }
        .sheet(isPresented: $picking) {
            ScheduleSheet(title: "Reschedule", start: message.schedule?.at ?? ScheduledSend.quickTimes()[0]) { date in
                picking = false
                if let date { Task { await store.reschedule(message, to: date) } }
            }
        }
    }
    private func open() { Task { await store.open(conversation: message.conversationID, thread: message.threadID) } }
    @ViewBuilder private var time: some View {
        if let schedule = message.schedule {
            Label(schedule.failed ? "Not sent" : ScheduledSend.when(schedule.at), systemImage: schedule.failed ? "exclamationmark.circle" : "clock")
                .font(.caption).foregroundStyle(schedule.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).fixedSize()
        }
    }
    private var buttons: some View {
        HStack(spacing: 10) {
            Button { Task { await store.sendNow(message) } } label: { Image(systemName: "paperplane") }.help("Send Now")
            Button { picking = true } label: { Image(systemName: "clock.arrow.circlepath") }.help("Reschedule")
            Button { Task { await store.unschedule(message) } } label: { Image(systemName: "trash") }.help("Delete")
        }
        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary).frame(height: 14)
    }
    @ViewBuilder private var reschedule: some View {
        ForEach(ScheduledSend.quickTimes(), id: \.self) { date in
            Button(ScheduledSend.when(date)) { Task { await store.reschedule(message, to: date) } }
        }
        Button("Choose Date and Time…") { picking = true }
    }
    @ViewBuilder private var actions: some View {
        Button("Send Now") { Task { await store.sendNow(message) } }
        Menu("Reschedule") { reschedule }
        Divider()
        Button("Delete", role: .destructive) { Task { await store.unschedule(message) } }
    }
}
