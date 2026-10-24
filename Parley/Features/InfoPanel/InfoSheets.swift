import ParleyDomain
import SwiftUI

/// People to add to a space or group: search by name or email, tick several, add them together.
struct AddPeopleSheet: View {
    @Environment(ChatStore.self) private var store
    let room: Conversation
    let roster: [Person]
    @State private var query = ""
    @State private var found: [Person] = []
    @State private var picked: [Person] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add people to “\(room.name)”").font(.headline)
            TextField("Name or email", text: $query).textFieldStyle(.roundedBorder)
            List(found.filter { person in !roster.contains { $0.id == person.id } }) { person in
                Toggle(
                    isOn: Binding(
                        get: { picked.contains(person) },
                        set: { on in
                            if on { picked.append(person) } else { picked.removeAll { $0 == person } }
                        })
                ) {
                    PersonRow(person.name, caption: person.emailCaption, avatarURL: person.avatarURL, size: 22)
                }.toggleStyle(.checkbox)
            }.frame(height: 260)
            Text(picked.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(18).frame(width: 420)
            .sheetButtons(
                "Add", enabled: !picked.isEmpty, cancel: { dismiss() },
                confirm: {
                    dismiss()
                    Task { await store.addMembers(picked, to: room.id) }
                }
            )
            .task(id: query) {
                guard await TypingPause.ended() else { return }
                found = (try? await store.searchPeople(matching: query)) ?? []
            }
    }
}

/// A space's description and guidelines, edited together and saved as one change, as Google Chat's details screen does.
struct SpaceDetailsSheet: View {
    @Environment(ChatStore.self) private var store
    let room: Conversation
    @State private var description = ""
    @State private var guidelines = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("“\(room.name)” details").font(.headline)
            Text("Description").font(.subheadline)
            TextField("What this space is for", text: $description, axis: .vertical).lineLimit(2...4)
            Text("Guidelines").font(.subheadline)
            TextField("How members should use this space", text: $guidelines, axis: .vertical).lineLimit(4...10)
        }
        .textFieldStyle(.roundedBorder).padding(18).frame(width: 420)
        .sheetButtons(
            "Save", cancel: { dismiss() },
            confirm: {
                dismiss()
                Task { await store.updateDetails(room.id, description: description, guidelines: guidelines) }
            }
        )
        .onAppear {
            description = room.description ?? ""
            guidelines = room.guidelines ?? ""
        }
    }
}
