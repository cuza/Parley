import ParleyDomain
import SwiftUI

/// A thread popped out of the pane: its first message and replies with their composer, as the pane shows them.
struct ThreadWindow: View {
    @Environment(ChatStore.self) private var store
    let ref: ThreadRef
    var body: some View {
        Group {
            if let room = store.rooms.conversations.first(where: { $0.id == ref.conversation }) {
                ThreadPane(room: room, thread: ref.thread, detached: true).navigationTitle("Thread").navigationSubtitle(
                    room.name)
            } else {
                ProgressView().navigationTitle("Thread")
            }
        }
        .frame(minWidth: ChatView.paneWidth, minHeight: 400)
        // A restored window loads its thread, or closes when the conversation isn't this account's.
        .task(id: store.hasConversation(ref.conversation)) {
            switch store.hasConversation(ref.conversation) {
            case true?: await store.load(ref.conversation, thread: ref.thread)
            case false?: dismissWindow()
            case nil: break
            }
        }
    }
    @Environment(\.dismissWindow) private var dismissWindow
}
