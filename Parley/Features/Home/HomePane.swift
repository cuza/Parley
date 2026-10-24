import SwiftUI

/// Home's list, with a thread row's thread open in the thread pane to its right.
struct HomePane: View {
    @Environment(ChatStore.self) private var store
    var body: some View {
        SidePaneSplit(open: store.navigation.threadID != nil && store.selected != nil) {
            ShortcutList(shortcut: .home)
        } pane: {
            if let thread = store.navigation.threadID, let room = store.selected {
                ThreadPane(room: room, thread: thread)
            }
        }
    }
}
