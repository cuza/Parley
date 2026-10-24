import AppKit
import ParleyDomain

extension MessageTable.Coordinator {
    // MARK: Swipe to reply (Telegram's chat gesture; logic in ReplySwipe)
    /// Returns true when the event belongs to a reply swipe and must not scroll the table.
    func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, let table else { return false }  // trackpad only, as Telegram
        // Positive moves toward the reply arrow (fingers moving left), whichever way natural scrolling is set.
        let toward = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaX : event.scrollingDeltaX
        let width = table.bounds.width
        if event.phase == .began {
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard row >= 0, !rows[row].message.isSystem,
                swipe.handle(.began, towardReply: toward, vertical: event.scrollingDeltaY, width: width) == .began
            else { return false }
            swipingRow = row
            swipe.allowsThread = parent?.identifier != "thread"  // inside a thread only quote applies
            return true
        }
        guard let index = swipingRow,
            let view = table.rowView(atRow: index, makeIfNecessary: false) as? MessageRowView
        else { return false }
        switch swipe.handle(event.phase, towardReply: toward, vertical: event.scrollingDeltaY, width: width) {
        case .moved(let offset, let stage, let crossed):
            if crossed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            view.setSwipe(offset: offset, stage: stage)
        case .committed(let stage):
            settle(view)
            guard rows.indices.contains(index), let actions = parent?.actions else { break }
            if stage == .thread {
                actions.openThread(rows[index].message)
            } else {
                actions.quote(rows[index].message)
            }
        case .cancelled:
            settle(view)
        case .began, .ignore:
            return false
        }
        return true
    }
    private func settle(_ view: MessageRowView) {
        swipingRow = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            view.setSwipe(offset: 0, stage: nil)
        }
    }
}
