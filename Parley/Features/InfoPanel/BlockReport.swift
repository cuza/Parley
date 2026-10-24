import ParleyDomain
import SwiftUI

/// Google Chat's Block and report: block only, or block and send Google a copy of the last 50 messages.
struct BlockSheet: View {
    enum Target: Identifiable, Hashable {
        case person(PersonID, name: String)
        case space(ConversationID, name: String)
        var id: String {
            switch self {
            case .person(let id, _): id.rawValue
            case .space(let id, _): id.rawValue
            }
        }
    }
    @Environment(ChatStore.self) private var store
    let target: Target
    @State private var report = false
    @Environment(\.dismiss) private var dismiss
    private var name: String {
        switch target {
        case .person(_, let name), .space(_, let name): name
        }
    }
    private var blockOnlyDetail: String {
        switch target {
        case .person:
            "\(name) won't be able to send you direct messages, and you won't see their messages in spaces. They can still read what you send in spaces."
        case .space: "You won't be invited to this space again, and it leaves your list."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Block \(name)?").font(.headline)
            Picker("", selection: $report) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Block only")
                    Text(blockOnlyDetail).font(.caption).foregroundStyle(.secondary)
                }.tag(false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Block and report to Google")
                    Text("Google receives a copy of the last 50 messages.").font(.caption).foregroundStyle(.secondary)
                }.tag(true)
            }.pickerStyle(.radioGroup).labelsHidden()
        }.padding(18).frame(width: 420)
            .sheetButtons(
                "Block", role: .destructive, cancel: { dismiss() },
                confirm: {
                    dismiss()
                    Task {
                        switch target {
                        case .person(let id, _): await store.block(person: id, report: report)
                        case .space(let id, _): await store.blockSpace(id, report: report)
                        }
                    }
                })
    }
}

/// Google Chat's Report this message: a reason and, if wanted, a short explanation, sent to the organisation's admin.
struct ReportSheet: View {
    @Environment(ChatStore.self) private var store
    let message: Message
    @State private var reason: ReportReason?
    @State private var explanation = ""
    @State private var working = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report this message").font(.headline)
            Text(
                "Choose the option that best describes why you're reporting this message. The report goes to your organization's admin."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $reason) {
                ForEach(ReportReason.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }.pickerStyle(.radioGroup).labelsHidden()
            TextField("Briefly explain the issue (optional)", text: $explanation, axis: .vertical).lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            if working { ProgressView().controlSize(.small) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }.padding(18).frame(width: 460)
            .sheetButtons(
                "Submit Report", enabled: reason != nil && !working, cancel: { dismiss() },
                confirm: {
                    guard let reason else { return }
                    working = true
                    problem = nil
                    Task {
                        defer { working = false }
                        do {
                            try await store.reportMessage(message, reason: reason, explanation: explanation)
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                })
    }
}

/// Settings ▸ Blocked: people and spaces I blocked, each with Unblock.
struct BlockedSection: View {
    @Environment(ChatStore.self) private var store
    @State private var spaces: [BlockedSpace] = []
    var body: some View {
        Section("Blocked") {
            if store.rooms.blockedPeople.isEmpty && spaces.isEmpty {
                Text("No one blocked").foregroundStyle(.secondary)
            }
            ForEach(store.rooms.blockedPeople.sorted(), id: \.self) { person in
                HStack {
                    Text(store.anyName(of: person)).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Unblock") { Task { await store.unblock(person: person) } }.controlSize(.small)
                }
            }
            ForEach(spaces) { space in
                HStack {
                    Avatar(name: space.name, space: true, size: 20)
                    Text(space.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Unblock") {
                        Task {
                            await store.unblockSpace(space.id)
                            spaces.removeAll { $0.id == space.id }
                        }
                    }.controlSize(.small)
                }
            }
        }
        .task {
            await store.loadBlocked()
            spaces = (try? await store.blockedSpaces()) ?? []
        }
    }
}

/// In place of the composer in a DM with someone I blocked, as Google Chat shows it.
struct BlockedCover: View {
    @Environment(ChatStore.self) private var store
    let person: PersonID
    let name: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("You blocked \(name)").font(.callout.weight(.semibold))
                Text("\(name) can't send you messages.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unblock") { Task { await store.unblock(person: person) } }
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(10)
    }
}
