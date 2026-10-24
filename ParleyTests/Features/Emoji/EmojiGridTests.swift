import AppKit
import SwiftUI
import Testing

@testable import Parley

struct EmojiGridTests {
    // Two sections: 5 emoji (rows of 3: 3 + 2), then 4 (3 + 1). Flat indices 0…4, 5…8.
    let sizes = [5, 4]
    @Test func leftAndRightStepThroughTheFlatList() {
        #expect(EmojiGrid.move(0, .left, sizes: sizes, columns: 3) == 0)
        #expect(EmojiGrid.move(4, .right, sizes: sizes, columns: 3) == 5)
        #expect(EmojiGrid.move(8, .right, sizes: sizes, columns: 3) == 8)
    }
    @Test func upAndDownKeepTheColumnAcrossSections() {
        #expect(EmojiGrid.move(1, .down, sizes: sizes, columns: 3) == 4)
        #expect(EmojiGrid.move(2, .down, sizes: sizes, columns: 3) == 4)  // the short last row: its last emoji
        #expect(EmojiGrid.move(4, .down, sizes: sizes, columns: 3) == 6)  // into the next section, same column
        #expect(EmojiGrid.move(6, .up, sizes: sizes, columns: 3) == 4)
        #expect(EmojiGrid.move(5, .up, sizes: sizes, columns: 3) == 3)
        #expect(EmojiGrid.move(8, .down, sizes: sizes, columns: 3) == 8)
        #expect(EmojiGrid.move(1, .up, sizes: sizes, columns: 3) == 1)
    }
}
