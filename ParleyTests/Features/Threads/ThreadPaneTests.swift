import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Parley

@MainActor
struct ThreadPaneTests {
    /// The thread pane's header draws the first message as the timeline does, held to four lines until clicked.
    @Test func theHeaderIsTheMessagesOwnTextLimitedToFourLines() {
        let long = Array(repeating: "A line of the thread's first message that wraps.", count: 12).joined(
            separator: " ")
        func height(_ lines: Int) -> CGFloat {
            let host = NSHostingView(
                rootView: NativeMessageText(text: long, own: false, lines: lines, maxWidth: .infinity).frame(width: 300)
            )
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let four = height(4)
        let all = height(0)
        #expect(four > 50 && four < 90)  // four lines of the 13 pt message font
        #expect(all > four * 2)
    }
}
