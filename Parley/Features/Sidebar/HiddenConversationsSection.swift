import SwiftUI

/// Settings ▸ Hidden conversations: what I hid from the sidebar (here or in Google Chat), each with a button to show it again.
struct HiddenConversationsSection: View {
    @Environment(ChatStore.self) private var store
    var body: some View {
        Section("Hidden conversations") {
            if store.rooms.hidden.isEmpty {
                Text("No hidden conversations").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.rooms.hidden) { room in
                            HStack(spacing: 8) {
                                Avatar(room: room, size: 20)
                                Text(room.name).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 8)
                                Button("Unhide") { Task { await store.unhide(room.id) } }
                                    .controlSize(.small).accessibilityLabel("Unhide \(room.name)")
                            }
                        }
                    }
                }
                .frame(maxHeight: 160).fixedSize(horizontal: false, vertical: true)  // grows with the list, then scrolls
            }
        }
    }
}
