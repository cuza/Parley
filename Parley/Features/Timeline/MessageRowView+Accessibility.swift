import AppKit
import ParleyDomain

extension MessageRowView {
    /// The row as VoiceOver reads it: the day when it starts one, who, the quote, the text, attachments, the time, and its
    /// state (edited, sending, not sent, seen by).
    static func spoken(_ row: TimelineRow, own: Bool) -> String {
        let message = row.message
        var parts: [String] = []
        if row.newDay { parts.append(message.createdAt.formatted(date: .complete, time: .omitted)) }
        if !message.isSystem { parts.append(own ? "You" : message.sender.name) }
        if let quote = message.quote { parts.append("replying to \(quote.sender): \(quote.text)") }
        let text = TextStyleRange.plain(message.text, message.formatting)
        if !text.isEmpty { parts.append(text) }
        parts += message.attachments.map(\.name).filter { !$0.isEmpty }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        if message.edited { parts.append("edited") }
        switch message.delivery {
        case .pending: parts.append("sending")
        case .failed: parts.append("not sent")
        case .sent: break
        }
        if !row.seenBy.isEmpty { parts.append("seen by " + row.seenBy.formatted(.list(type: .and))) }
        return parts.joined(separator: ", ")
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        contextMenu().items.compactMap { $0 as? ClosureMenuItem }.filter(\.isEnabled).map { item in
            NSAccessibilityCustomAction(name: item.title) {
                item.handler()
                return true
            }
        }
    }
}
