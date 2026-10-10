import SwiftUI

/// Settings ▸ Hidden conversations: what I hid from the sidebar (here or in Google Chat), each with a button to show it again.
struct HiddenConversationsSection: View {
    let store: ChatStore
    var body: some View {
        LabeledContent("Hidden conversations") {
            if store.hidden.isEmpty {
                Text("No hidden conversations").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.hidden) { room in
                            HStack(spacing: 8) {
                                Avatar(name: room.name, space: room.kind == .space, size: 20, url: room.avatarURL, emoji: room.emoji)
                                Text(room.name).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 8)
                                Button("Unhide") { Task { await store.unhide(room.id) } }
                                    .controlSize(.small).accessibilityLabel("Unhide \(room.name)")
                            }
                        }
                    }
                }
                .frame(maxHeight: 160).fixedSize(horizontal: false, vertical: true)   // grows with the list, then scrolls
            }
        }
    }
}
