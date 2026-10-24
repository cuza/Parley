import ParleyDomain
import SwiftUI

/// Google Chat's search chips: From, Date, Has and Mentions me. A chip in use is tinted and says what it picked.
struct SearchChips: View {
    @Environment(ChatStore.self) private var store
    @Binding var filters: SearchFilters
    @State private var pickingPeople = false
    @State private var pickingConversations = false
    @State private var pickingDates = false
    var body: some View {
        HStack(spacing: 6) {
            chip(
                filters.from.isEmpty
                    ? "From" : "From: " + ListFormatter.localizedString(byJoining: filters.from.map(\.name)),
                on: !filters.from.isEmpty
            ) {
                pickingPeople = true
            }
            .popover(isPresented: $pickingPeople, arrowEdge: .bottom) { PeoplePicker(picked: $filters.from) }
            let names = filters.saidIn.compactMap { id in store.rooms.conversations.first { $0.id == id }?.name }
            chip(
                names.isEmpty ? "Said in" : "Said in: " + ListFormatter.localizedString(byJoining: names),
                on: !filters.saidIn.isEmpty
            ) {
                pickingConversations = true
            }
            .popover(isPresented: $pickingConversations, arrowEdge: .bottom) {
                ConversationPicker(picked: $filters.saidIn)
            }
            Menu {
                Button("Any Time") {
                    filters.after = nil
                    filters.before = nil
                }
                ForEach(SearchFilters.Age.allCases, id: \.self) { age in
                    Button(age.rawValue) {
                        filters.after = nil
                        filters.before = age.before(now: .now)
                    }
                }
                Button("Custom Range…") { pickingDates = true }
            } label: {
                Text(dateTitle)
            }
            .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
            .tint(filters.after != nil || filters.before != nil ? .accentColor : nil)
            Menu {
                ForEach(SearchFilters.Kind.allCases, id: \.self) { kind in
                    Toggle(
                        kind.rawValue,
                        isOn: Binding(get: { filters.has.contains(kind) }, set: { _ in filters.toggle(kind) }))
                }
            } label: {
                Text(
                    filters.has.isEmpty
                        ? "Has"
                        : "Has: "
                            + SearchFilters.Kind.allCases.filter(filters.has.contains).map(\.rawValue).joined(
                                separator: ", "))
            }
            .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
            .tint(filters.has.isEmpty ? nil : .accentColor)
            chip("Mentions me", on: filters.mentionsMe) { filters.mentionsMe.toggle() }
            Spacer(minLength: 0)
            if !filters.isEmpty { Button("Clear") { filters = SearchFilters() }.buttonStyle(.link).controlSize(.small) }
        }
        .sheet(isPresented: $pickingDates) {
            DateRangeSheet { range in
                pickingDates = false
                if let range {
                    filters.after = range.lowerBound
                    filters.before = range.upperBound
                }
            }
        }
    }
    private var dateTitle: String {
        switch (filters.after, filters.before) {
        case (nil, nil): return "Date"
        case (nil, let before?):
            return SearchFilters.Age.allCases.first { abs($0.before(now: .now).timeIntervalSince(before)) < 86_400 }?
                .rawValue
                ?? "Before \(before.formatted(date: .abbreviated, time: .omitted))"
        case (let after?, let before):
            let end = before.map { $0.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted) } ?? "now"
            return "\(after.formatted(date: .abbreviated, time: .omitted)) – \(end)"
        }
    }
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.small).tint(on ? .accentColor : nil)
            .lineLimit(1)
    }
}

/// People to search messages from: me, then anyone found by name.
private struct PeoplePicker: View {
    @Environment(ChatStore.self) private var store
    @Binding var picked: [Person]
    @State private var query = ""
    @State private var found: [Person] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name or email", text: $query).textFieldStyle(.roundedBorder)
            ForEach([store.me] + found.filter { $0.id != store.me.id }, id: \.id) { person in
                Toggle(
                    isOn: Binding(
                        get: { picked.contains { $0.id == person.id } },
                        set: { on in
                            if on { picked.append(person) } else { picked.removeAll { $0.id == person.id } }
                        })
                ) {
                    HStack(spacing: 6) {
                        Avatar(name: person.name, size: 18, url: person.avatarURL)
                        Text(person.id == store.me.id ? "Me" : person.name).lineLimit(1)
                    }
                }.toggleStyle(.checkbox)
            }
        }
        .padding(12).frame(width: 240)
        .task(id: query) {
            guard await TypingPause.ended(), !query.isEmpty else {
                found = picked.filter { $0.id != store.me.id }
                return
            }
            found = (try? await store.searchPeople(matching: query)) ?? []
        }
    }
}

/// Conversations to search in: the picked ones, then the rest by recent activity, narrowed by name.
private struct ConversationPicker: View {
    @Environment(ChatStore.self) private var store
    @Binding var picked: [ConversationID]
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Conversation name", text: $query).textFieldStyle(.roundedBorder)
            ForEach(shown) { room in
                Toggle(
                    isOn: Binding(
                        get: { picked.contains(room.id) },
                        set: { on in
                            if on { picked.append(room.id) } else { picked.removeAll { $0 == room.id } }
                        })
                ) {
                    HStack(spacing: 6) {
                        Avatar(room: room, size: 18)
                        Text(room.name).lineLimit(1).truncationMode(.tail)
                    }
                }.toggleStyle(.checkbox)
            }
        }
        .padding(12).frame(width: 260)
    }
    private var shown: [Conversation] {
        let matching = store.rooms.conversations.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        .sorted { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }
        return Array(
            (matching.filter { picked.contains($0.id) } + matching.filter { !picked.contains($0.id) }).prefix(8))
    }
}

/// A custom date range, whole days: the end day counts, as in Google Chat.
private struct DateRangeSheet: View {
    let done: (Range<Date>?) -> Void
    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var end = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Range").font(.headline)
            DatePicker("From", selection: $start, in: ...end, displayedComponents: .date)
            DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
        }
        .padding(20).frame(width: 300)
        .sheetButtons(
            "Apply", cancel: { done(nil) },
            confirm: {
                let calendar = Calendar.current
                let from = calendar.startOfDay(for: start)
                let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
                done(from..<to)
            })
    }
}
