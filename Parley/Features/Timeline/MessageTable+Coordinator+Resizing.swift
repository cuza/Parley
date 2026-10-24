import AppKit
import ParleyDomain

extension MessageTable.Coordinator {
    /// Width changed. During a live resize only the visible rows are re-measured (the rest keep their last layout);
    /// `liveResizeEnded` re-measures everything, as Telegram does.
    @objc func tableResized() {
        guard let table, let scroll else { return }
        guard table.bounds.width != measuredWidth else {
            if pinnedToBottom { keepingPlace {} }
            return
        }  // grew taller: follow
        measuredWidth = table.bounds.width
        if scroll.inLiveResize { resizing = true }
        guard resizing else { return remeasure() }
        remeasuring?.cancel()
        // Mid-resize, as TelegramSwift's TableView does: the rows in view are measured again at the new width and
        // redrawn with it, so none shows clipped; rows out of view keep their layouts until the resize ends.
        let visible = table.rows(in: scroll.documentVisibleRect)
        let indexes = IndexSet(integersIn: visible.location..<min(rows.count, visible.location + visible.length))
        for index in indexes { _ = fresh(rows[index]) }
        relayout(indexes, in: table)
        if scroll.inLiveResize { settleAfterResize() }
    }
    /// An animated resize (a pane opening grows the window, the zoom button) is a live resize that never posts its
    /// end: once resizing stops, re-measure every row. A drag still going on is left to `liveResizeEnded`.
    private func settleAfterResize() {
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let scroll, !scroll.inLiveResize else { return }
            remeasure()
        }
    }
    /// A card's picture loaded at a size not known before: the cards that hug it are re-measured, keeping the reader's place.
    @objc func pictureSized(_ note: Notification) {
        guard let table, let url = note.object as? URL else { return }
        let indexes = IndexSet(
            rows.indices.filter { index in
                rows[index].message.attachments.contains {
                    $0.card?.sections.joined().contains {
                        if case .image(url, _, _, _) = $0 { true } else { false }
                    } == true
                }
            })
        guard !indexes.isEmpty else { return }
        for index in indexes {
            layouts[rows[index]] = nil
            _ = fresh(rows[index])
        }
        relayout(indexes, in: table)
    }
    /// View ▸ Bigger or Smaller: every row is laid out again at the new size, keeping the place in the conversation.
    @objc func textSizeChanged(_ note: Notification) {
        guard let table, !rows.isEmpty else { return }
        layouts.removeAll()
        relayout(IndexSet(rows.indices), in: table)
    }
    /// Tells the table these rows' heights changed, keeping the reader's place, and shows each row's new layout.
    private func relayout(_ indexes: IndexSet, in table: NSTableView) {
        keepingPlace { table.noteHeightOfRows(withIndexesChanged: indexes) }
        indexes.forEach(configureRow)
    }
    @objc func liveResizeEnded(_ note: Notification) {
        guard let window = scroll?.window, note.object as? NSWindow === window else { return }
        remeasure()
    }
    /// Re-measures every row at the table's width, nearest the reader first: the rows in view and `chunk` around them
    /// at once, then as many per turn of the run loop, so a long history doesn't stall the frame where a resize ends.
    /// A row keeps its last layout until its turn; each chunk keeps the reader's place.
    static let chunk = 50
    private func remeasure() {
        remeasuring?.cancel()
        resizing = false
        settling = true
        guard measureNext() else { return }
        remeasuring = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))  // lets the frame draw
                guard !Task.isCancelled, let self, measureNext() else { return }
            }
        }
    }
    /// Measures the next chunk; false once every row is measured at the table's width.
    private func measureNext() -> Bool {
        guard let table, let scroll, table.bounds.width > 50 else {
            settling = false
            due = nil
            return false
        }
        let width = table.bounds.width
        let visible = table.rows(in: scroll.documentVisibleRect)
        if due == nil || dueWidth != width {
            let middle = visible.location + visible.length / 2
            due = rows.indices.filter { layouts[rows[$0]]?.first?.width != width }.sorted {
                abs($0 - middle) > abs($1 - middle)
            }
            dueWidth = width
        }
        let stale = { (index: Int) in
            index < self.rows.count && self.layouts[self.rows[index]]?.first?.width != width
        }
        // What is on screen now first (the reader may have scrolled meanwhile), then the next in line.
        var next = IndexSet((visible.location..<visible.location + visible.length).filter(stale))
        while next.count < visible.length + Self.chunk, let index = due?.popLast() {
            if stale(index) { next.insert(index) }
        }
        for index in next { _ = fresh(rows[index]) }
        relayout(next, in: table)
        settling = !(due ?? []).isEmpty
        if !settling { due = nil }
        return settling
    }
}
