import Foundation
import Testing

@testable import Parley

/// The typing bubble at the end of the conversation, as Messages shows it: who is typing, by name over a thought bubble.
struct TypingBubbleTests {
    @Test func itNamesWhoIsTyping() {
        #expect(TypingBubble.title(["Maria Chen"]) == "Maria Chen")
        #expect(TypingBubble.title(["Maria Chen", "Alex Rivera"]) == "Maria and Alex")
        // The list as this Mac's language writes it ("Maria, Alex and Sam" in some, a serial comma in others).
        #expect(
            TypingBubble.title(["Maria Chen", "Alex Rivera", "Sam Lee"])
                == ListFormatter.localizedString(byJoining: ["Maria", "Alex", "Sam"]))
        #expect(TypingBubble.title(["Maria Chen", "Alex Rivera", "Sam Lee", "Kim Park"]) == "Several people")
    }
}
