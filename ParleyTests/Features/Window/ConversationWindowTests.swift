import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Parley

@MainActor
struct ConversationWindowTests {
    /// A conversation opened in its own window shows just that conversation: no sidebar until asked for.
    @Test func aConversationWindowOpensWithoutTheSidebar() {
        #expect(ChatView.initialColumns(fixedConversation: "space/x") == .detailOnly)
        #expect(ChatView.initialColumns(fixedConversation: nil) == .all)
    }
    /// Every window shares the store, so a pane opening is seen by all of them: each grows only its own window.
    @Test func growingForAPaneTouchesOnlyThatWindow() {
        let mine = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        ChatView.makeRoom(701, in: mine, animate: false)
        #expect(mine.frame.width >= 701)
        #expect(other.frame.width == 380)
    }
    /// Opening a pane there grows the window by the pane alone, not as if a sidebar were beside it.
    @Test func aConversationWindowCountsNoSidebar() {
        #expect(ChatView.shownSidebar(fixedConversation: "space/x", columns: .all, measured: 230) == 0)
        #expect(ChatView.shownSidebar(fixedConversation: nil, columns: .all, measured: 230) == 230)
        #expect(ChatView.shownSidebar(fixedConversation: nil, columns: .detailOnly, measured: 230) == 0)
    }
}
