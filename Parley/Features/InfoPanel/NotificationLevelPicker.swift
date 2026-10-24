import ParleyDomain
import SwiftUI

/// When the conversation notifies me, in web Chat's words; a pick is shown at once and sent (put back if refused).
/// In a menu it is a submenu.
struct NotificationLevelPicker: View {
    @Environment(ChatStore.self) private var store
    let room: Conversation
    var body: some View {
        Picker(
            "Notifications",
            selection: Binding(
                get: { room.notificationLevel },
                set: { level in
                    if let level, level != room.notificationLevel {
                        Task { await store.setNotificationLevel(level, room.id) }
                    }
                })
        ) {
            ForEach(NotificationLevel.choices(for: room.kind, current: room.notificationLevel), id: \.self) {
                Text($0.title).tag(Optional($0))
            }
        }
    }
}
