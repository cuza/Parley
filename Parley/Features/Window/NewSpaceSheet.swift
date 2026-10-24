import SwiftUI

/// Google Chat's Create a space: a name and, if wanted, an emoji. The space opens once Google has made it.
struct NewSpaceSheet: View {
    @Environment(ChatStore.self) private var store
    @State private var name = ""
    @State private var emoji: String?
    @State private var pickingEmoji = false
    @State private var working = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Space").font(.headline)
            HStack(spacing: 10) {
                Button {
                    pickingEmoji = true
                } label: {
                    Avatar(name: name.isEmpty ? "?" : name, space: true, size: 36, emoji: emoji)
                }.buttonStyle(.plain).help("Choose an emoji")
                    .emojiPickerPopover(isPresented: $pickingEmoji) { emoji = $0 }
                TextField("Space name", text: $name).textFieldStyle(.roundedBorder)
                    .onChange(of: name) { if name.count > 128 { name = String(name.prefix(128)) } }  // Google Chat's limit
            }
            if working { ProgressView().controlSize(.small) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }.padding(18).frame(width: 380)
            .sheetButtons(
                "Create", enabled: !working && !name.trimmingCharacters(in: .whitespaces).isEmpty,
                cancel: { dismiss() },
                confirm: {
                    working = true
                    problem = nil
                    Task {
                        defer { working = false }
                        do {
                            try await store.createSpace(name: name, emoji: emoji)
                            dismiss()
                        } catch { problem = error.localizedDescription }
                    }
                })
    }
}
