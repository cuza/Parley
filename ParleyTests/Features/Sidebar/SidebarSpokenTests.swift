import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

/// The sidebar row as VoiceOver reads it.
@MainActor struct SidebarSpokenTests {
    @Test func readsUnreadPinnedAndMutedOnlyWhenSo() {
        var room = Conversation.fixture("s")
        #expect(ChatView.spoken(room) == "Design")  // not "0 unread"
        room.unread = 3
        room.pinned = true
        room.muted = true
        #expect(ChatView.spoken(room) == "Design, 3 unread, pinned, muted")
    }
}
