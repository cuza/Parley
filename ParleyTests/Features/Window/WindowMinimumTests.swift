import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Parley

@MainActor
struct WindowMinimumTests {
    /// The window's needs are the sum of the shown areas: the sidebar at its measured width, the timeline's minimum and,
    /// while open, the side pane.
    @Test func theNeededWidthIsTheShownAreas() {
        #expect(ChatView.minWidth(paneOpen: false, sidebar: 0) == ChatView.timelineMinWidth)
        #expect(ChatView.minWidth(paneOpen: true, sidebar: 0) == ChatView.timelineMinWidth + 1 + ChatView.paneWidth)
        #expect(
            ChatView.minWidth(paneOpen: true, sidebar: 230) == 230 + ChatView.timelineMinWidth + 1 + ChatView.paneWidth)
    }
    /// Opening a pane grows the window only by what it lacks, never past what the shown areas need.
    @Test func openingAPaneGrowsTheWindowOnlyToWhatItNeeds() {
        #expect(ChatView.widthForPane(window: 380, sidebar: 0) == 721)
        #expect(ChatView.widthForPane(window: 760, sidebar: 230) == 951)
        #expect(ChatView.widthForPane(window: 1400, sidebar: 230) == 1400)  // room already: unchanged
    }
    @Test func theSidebarHidesWhenTheWindowNarrowsAndReturnsWhenItWidens() {
        let fits = ChatView.minWidth(paneOpen: true, sidebar: 230)
        func decide(_ width: CGFloat, _ visible: Bool, _ autoHidden: Bool) -> (visible: Bool, autoHidden: Bool) {
            ChatView.sidebar(width: width, paneOpen: true, sidebarWidth: 230, visible: visible, autoHidden: autoHidden)
        }
        #expect(decide(fits - 1, true, false) == (visible: false, autoHidden: true))  // too narrow: we hide it
        #expect(decide(fits, false, true) == (visible: true, autoHidden: false))  // room again: back
        #expect(decide(fits + 400, false, false) == (visible: false, autoHidden: false))  // hidden by the user: stays
    }
}
