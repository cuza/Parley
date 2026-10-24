import AppIntents
import AppKit
import ParleyDomain

extension MessageTable {
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var scroll: NSScrollView?
        var parent: MessageTable?
        private(set) var rows: [TimelineRow] = []
        /// Each row's layouts at its last few widths, the one in use first: going back to a recent width (a pane
        /// closing again) reuses them.
        var layouts: [TimelineRow: [RowLayout]] = [:]
        static let widthsKept = 3
        var measuredWidth: CGFloat = 0
        /// A live resize is under way: rows keep their layouts until it ends. Our own flag, because AppKit still reports
        /// `inLiveResize` while it posts the resize's end, which would keep the old layouts for the final re-measure.
        var resizing = false
        /// After a resize, rows not yet re-measured keep their last layout until `remeasure` reaches them.
        var settling = false
        var wasNearTop = false
        var rowsAtNearTop = 0  // the row count when the table last asked for older history
        var wasNearBottom = false
        var rowsAtNearBottom = 0
        var keeping = false
        /// Whether the reader is following the newest message. Only scrolling changes it, not layout passes: SwiftUI
        /// briefly lays the timeline out at transient sizes, which would otherwise read as having scrolled away.
        var pinnedToBottom = true
        var lastClipSize: NSSize = .zero
        var wasAtBottom = true
        private var highlighted: MessageID?
        var table: NSTableView? { scroll?.documentView as? NSTableView }
        /// Quick Look, drag out and the attachment menu for this timeline's attachments.
        let files = AttachmentFiles { _, _ in throw CancellationError() }
        static let reportsForUITests = ProcessInfo.processInfo.arguments.contains("-uiTestingLongHistory")

        private(set) var updates = 0  // how often SwiftUI handed the table new rows: tests check that typing doesn't
        func update(_ parent: MessageTable) {
            updates += 1
            let changedLook =
                self.parent.map {
                    $0.meID != parent.meID || $0.kind != parent.kind || $0.style != parent.style
                        || $0.look != parent.look
                } ?? false
            let wantsBottom = self.parent.map { $0.scrollRequest != parent.scrollRequest } ?? false
            self.parent = parent
            files.load = parent.actions.loadAttachment
            guard let table, let scroll else { return }
            if scroll.contentInsets.bottom != parent.bottomInset {
                keepingPlace {
                    // The clip view clamps scrolling to its own insets, which the scroll view only copies on a later tile;
                    // until then a pinned reader is pulled back under the composer. Set both at once.
                    scroll.contentInsets.bottom = parent.bottomInset
                    scroll.contentView.contentInsets.bottom = parent.bottomInset
                    scroll.tile()
                }
            }
            if parent.rows != rows || changedLook {
                let old = rows
                // My send just appeared (pending): show it. A page that merely ends with an older message of mine (a window
                // meeting the newest messages) is not a send.
                let ownNew =
                    parent.rows.last?.id != old.last?.id && parent.rows.last?.message.sender.id == parent.meID
                    && parent.rows.last?.message.delivery == .pending
                if changedLook { layouts = [:] }  // who "me" is decides alignment: cached layouts are for the old identity
                // A window opened at a message shows that message (below), not its end.
                keepingPlace(toBottom: (old.isEmpty && !parent.detached) || ownNew) {
                    apply(old: old, new: parent.rows, everything: changedLook, in: table)
                }
                checkNearTop()  // a page landed and the reader may still be near the top: ask for the next one
                checkNearBottom()
            }
            if parent.highlighted != highlighted {
                let affected = [highlighted, parent.highlighted].compactMap { id in rows.firstIndex { $0.id == id } }
                highlighted = parent.highlighted
                affected.forEach(configureRow)
                if let id = parent.highlighted, let index = rows.firstIndex(where: { $0.id == id }) { center(index) }
            }
            if wantsBottom { scrollToBottom() }
        }
        /// Telegram-style diff: older rows inserted above, newer appended, changed rows re-measured and reconfigured in place.
        private func apply(old: [TimelineRow], new: [TimelineRow], everything: Bool, in table: NSTableView) {
            rows = new
            due = nil  // indexes into the old rows
            // A changed row (an edit, a reaction, a receipt, a streamed answer) is a new key; the old ones go once they pile up.
            if layouts.count > rows.count + 100 {
                let current = Set(rows)
                layouts = layouts.filter { current.contains($0.key) }
            }
            let oldIDs = old.map(\.id)
            let newIDs = new.map(\.id)
            let prepended = newIDs.ends(with: oldIDs)
            let appended = newIDs.starts(with: oldIDs)
            guard !everything, !old.isEmpty, prepended || appended else {
                prefetchQueue = []  // another conversation: the previous one's thumbnails are no longer wanted
                prefetchThumbnails(new)
                table.reloadData()
                return
            }
            let offset = prepended ? newIDs.count - oldIDs.count : 0
            if prepended { prefetchThumbnails(new[..<offset]) }
            table.beginUpdates()
            if prepended, offset > 0 {
                table.insertRows(at: IndexSet(integersIn: 0..<offset), withAnimation: [])
            } else if new.count > old.count {
                table.insertRows(at: IndexSet(integersIn: old.count..<new.count), withAnimation: [])
            }
            let changed = IndexSet(old.indices.filter { old[$0] != new[$0 + offset] }.map { $0 + offset })
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
            table.endUpdates()
            changed.forEach(configureRow)
        }
        /// Runs a change, then puts the first row wholly in view back where it was, or stays at the bottom if the reader was
        /// there. The row is found again by id.
        func keepingPlace(toBottom: Bool = false, _ change: () -> Void) {
            // Re-measuring resizes the table, whose frame change re-enters here mid-update; only the outermost call,
            // which saw the state before any of it, decides where the reader ends up.
            guard let scroll, let table, !keeping else { return change() }
            keeping = true
            defer { keeping = false }
            let visible = scroll.contentView.bounds
            let atBottom = toBottom || (pinnedToBottom && parent?.detached != true)  // a window's end isn't the newest message
            // Not the row cut off at the top: when it re-wraps (a resize), every row below would move by its change.
            let inView = table.rows(in: uncovered)
            let top = uncovered.minY
            let first =
                (inView.location..<inView.location + inView.length).first { table.rect(ofRow: $0).minY >= top }
                ?? inView.location
            let anchor =
                first < rows.count ? (id: rows[first].id, offset: table.rect(ofRow: first).minY - visible.minY) : nil
            // NSTableView animates height changes from `noteHeightOfRows` (~0.25 s) while the scroll position below is
            // already final: rows slide and settle (a wiggle when a receipt moves, every row after a resize). Apply them
            // at once, as Telegram does.
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            change()
            NSAnimationContext.endGrouping()
            table.tile()  // out of Auto Layout (see makeScrollView), the table resizes to its rows only when tiled
            table.layoutSubtreeIfNeeded()
            var target: CGFloat
            if atBottom {
                target = bottomOrigin
            } else if let anchor, let index = rows.firstIndex(where: { $0.id == anchor.id }) {
                target = table.rect(ofRow: index).minY - anchor.offset
            } else {
                return
            }
            target = min(target, bottomOrigin)  // never past the content
            pinnedToBottom = atBottom
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(-scroll.contentInsets.top, target)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        /// The pending re-measure after an animated resize (`settleAfterResize`).
        var settle: Task<Void, Never>?
        /// The re-measure under way, a chunk per turn of the run loop (`remeasure`).
        var remeasuring: Task<Void, Never>?
        /// The rows a re-measure still has to do at `dueWidth`, farthest from the reader first (taken from the end): made
        /// once per re-measure, not once per chunk, which over a long history was a filter and sort per millisecond.
        var due: [Int]?
        var dueWidth: CGFloat = 0

        /// Thumbnails of a page that just landed, warmed into `ImageCache` before their rows scroll into view;
        /// at most `prefetchLimit` at a time, nearest to the reader first, best effort.
        private var prefetchQueue: [Attachment] = []
        private var prefetchers = 0
        static let prefetchLimit = 4
        private func prefetchThumbnails(_ rows: some Collection<TimelineRow>) {
            prefetchQueue += rows.flatMap(\.message.attachments).filter { $0.kind == .image || $0.kind == .video }
            while prefetchers < Self.prefetchLimit, !prefetchQueue.isEmpty {
                prefetchers += 1
                Task { [weak self] in
                    while let attachment = self?.prefetchQueue.popLast(),
                        let load = self?.parent?.actions.loadAttachment
                    {
                        _ = try? await ImageCache.load(attachment, load)
                    }
                    self?.prefetchers -= 1
                }
            }
        }

        /// The row's layout at the current width. During and just after a resize, rows not re-measured yet keep the one in use.
        func layout(_ row: TimelineRow) -> RowLayout? {
            if resizing || settling, let inUse = layouts[row]?.first { return inUse }
            return fresh(row)
        }
        /// The row's layout at the table's width: a kept one, else measured now.
        func fresh(_ row: TimelineRow) -> RowLayout? {
            guard let parent, let table, table.bounds.width > 50 else { return nil }
            let width = table.bounds.width
            let kept = layouts[row] ?? []
            if let index = kept.firstIndex(where: { $0.width == width }) {
                if index > 0 { layouts[row] = [kept[index]] + kept.filter { $0.width != width } }
                return kept[index]
            }
            let layout = RowLayout.make(
                row, width: width, own: row.message.sender.id == parent.meID, kind: parent.kind, style: parent.style)
            layouts[row] = [layout] + kept.prefix(Self.widthsKept - 1)
            return layout
        }
        func configureRow(_ index: Int) {
            guard let view = table?.rowView(atRow: index, makeIfNecessary: false) as? MessageRowView else { return }
            configure(view, index)
        }
        private func configure(_ view: MessageRowView, _ index: Int) {
            guard let parent else { return }
            let row = rows[index]
            var actions = parent.actions
            actions.files = files
            view.layoutFor = { [weak self] in self?.layout($0) }  // the table's layouts: the row view never measures its own
            view.configure(
                row, own: row.message.sender.id == parent.meID, kind: parent.kind, meID: parent.meID,
                layout: layout(row), highlighted: row.id == parent.highlighted, style: parent.style, actions: actions)
        }

        /// The reply swipe under way (`handleSwipe`).
        var swipe = ReplySwipe()
        var swipingRow: Int?

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { layout(rows[row])?.height ?? 44 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view =
                tableView.makeView(withIdentifier: .init("message"), owner: nil) as? MessageRowView
                ?? {
                    let view = MessageRowView()
                    view.identifier = .init("message")
                    return view
                }()
            configure(view, row)
            return view
        }
        /// A message can be selected, to act on it from the keyboard (see `TimelineTableView`).
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) }
        /// The selected message, by its key: Return replies (in its thread, in a space's timeline), R quotes it, E edits and
        /// Delete deletes one of mine, ⌘C copies it. Writing (a quote, an edit) takes the keyboard back to the composer.
        func act(_ key: TimelineTableView.Key, on row: Int, in table: TimelineTableView) {
            guard rows.indices.contains(row), let parent else { return }
            let message = rows[row].message
            let mine = message.sender.id == parent.meID
            switch key {
            case .reply where parent.kind == .space && parent.identifier == "timeline" && message.threadID == nil:
                parent.actions.openThread(message)
            case .reply, .quote:
                parent.actions.quote(message)
                table.leave()
            case .edit:
                if mine {
                    parent.actions.edit(message)
                    table.leave()
                }
            case .delete: if mine { parent.actions.delete(message) }
            case .copy:
                if let view = table.rowView(atRow: row, makeIfNecessary: false) as? MessageRowView {
                    view.copyMessage()
                } else {
                    parent.actions.copy(message)
                }
            }
        }
    }
}

extension Array where Element: Equatable {
    fileprivate func ends(with suffix: [Element]) -> Bool {
        suffix.count <= count && Array(self[(count - suffix.count)...]) == suffix
    }
}

/// "Summarize this message", "reply to that": each visible row names its message for Siri.
@available(macOS 27, *)
extension MessageTable.Coordinator: NSTableViewAppIntentsDataSource {
    func tableView(_ tableView: NSTableView, appEntityIdentifierFor row: Int) -> EntityIdentifier? {
        rows.indices.contains(row)
            ? EntityIdentifier(for: SiriMessage.self, identifier: rows[row].message.id.rawValue) : nil
    }
}
