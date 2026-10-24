import AppKit
import Foundation
import SwiftProtobuf
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Lists in message text: numbered ones count, nested ones step in, as Google Chat draws them.
struct MessageListTests {
    private func item(_ start: Int, _ length: Int, type: Int32, level: Int32) -> Dynamite_Annotation {
        .with {
            $0.type = .formatData
            $0.startIndex = Int32(start)
            $0.length = Int32(length)
            $0.formatMetadata = .with {
                $0.formatType = .bulletedListItem
                $0.list = .with {
                    $0.listType = type
                    $0.nestingLevel = level
                }
            }
        }
    }
    @Test func numberedAndNestedListItemsAreKept() {
        // "a\nb\nc\nd\ne": a, b numbered; c nested under b, numbered from 1; d back at the top, 3; e a nested bullet.
        let text = "a\nb\nc\nd\ne"
        let (_, formatting) = DynamiteMapper.richText(
            text,
            [
                item(0, 2, type: 2, level: 0), item(2, 2, type: 2, level: 0), item(4, 2, type: 2, level: 1),
                item(6, 2, type: 2, level: 0), item(8, 1, type: 1, level: 1),
            ])
        #expect(
            formatting.map(\.style) == [
                .list(level: 0, number: 1), .list(level: 0, number: 2), .list(level: 1, number: 1),
                .list(level: 0, number: 3), .list(level: 1, number: nil),
            ])
        // A plain top-level bullet stays the composer's own style.
        #expect(DynamiteMapper.richText("a", [item(0, 1, type: 1, level: 0)]).formatting.map(\.style) == [.listItem])
    }
    @Test func aListDrawsItsNumbersAndBullets() {
        let styled = MessageTextStyle.styled(
            "a\nb",
            [
                TextStyleRange(style: .list(level: 0, number: 1), start: 0, length: 2),
                TextStyleRange(style: .list(level: 1, number: nil), start: 2, length: 1),
            ], own: false)
        #expect(styled.string == "1. a\n◦ b")
        let nested = styled.attribute(.paragraphStyle, at: styled.length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect(nested?.firstLineHeadIndent == 16)
    }
    @Test func aListIsSentBackAsItCame() {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .list(level: 1, number: 2), start: 0, length: 1)])
        #expect(sent.first?.formatMetadata.list.nestingLevel == 1 && sent.first?.formatMetadata.list.listType == 2)
    }
}
