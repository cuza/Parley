import AppKit
import ParleyDomain

extension MessageRowView {
    /// Custom emoji draw a placeholder until `ImageCache` has their picture; this fetches the missing ones, then redraws.
    func loadCustomEmoji(_ message: Message) {
        let text = (message.formatting + (message.quote?.emoji ?? [])).compactMap { range -> CustomEmoji? in
            if case .customEmoji(let emoji) = range.style { emoji } else { nil }
        }
        let all = Set((text + message.reactions.compactMap(\.custom)).compactMap(\.image))
        let pictures = all.filter { ImageCache.cached($0) == nil }
        emojiTask?.cancel()
        emojiAnimation.update(all)
        guard !pictures.isEmpty else { return }
        let load = actions.loadAttachment
        emojiTask = Task { [weak self] in
            for picture in pictures { _ = try? await ImageCache.load(picture, load) }
            guard let self, !Task.isCancelled else { return }
            redrawEmoji()
            emojiAnimation.update(all)
        }
    }
    func redrawEmoji() {
        textView.needsDisplay = true
        quoteTextLabel.needsDisplay = true
        reactionPills.forEach { $0.needsDisplay = true }
    }
}
