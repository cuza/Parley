import SwiftUI

/// A space's threads, newest reply first, as Google Chat's Active threads lists them: Following, Unread and Mentions
/// narrow the list together. A click opens the thread over the list; closing it comes back here.
struct ThreadsPane: View {
    @Bindable var store: ChatStore
    let room: Conversation
    @AppStorage("threadsFilters") private var saved = ""   // the chosen filters, kept between launches
    private var filters: Set<ThreadSummary.Filter> { Set(saved.split(separator: ",").compactMap { ThreadSummary.Filter(rawValue: String($0)) }) }
    private func toggle(_ filter: ThreadSummary.Filter) {
        var chosen = filters
        if chosen.contains(filter) { chosen.remove(filter) } else { chosen.insert(filter) }
        saved = ThreadSummary.Filter.allCases.filter(chosen.contains).map(\.rawValue).joined(separator: ",")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Threads").font(.headline); Spacer()
                Button { Task { await store.showThreads(false) } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close")
            }.padding()
            HStack(spacing: 6) {
                ForEach(ThreadSummary.Filter.allCases, id: \.self) { filter in
                    Toggle(filter.rawValue, isOn: Binding(get: { filters.contains(filter) }, set: { _ in toggle(filter) }))
                        .toggleStyle(.button).controlSize(.small)
                }
                Spacer()
            }.padding(.horizontal).padding(.bottom, 10)
            Divider()
            content.frame(maxHeight: .infinity)
        }
        // The side pane gives a width only: fill its height, header at the top, as the other panes do.
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: room.id) { await store.loadThreads(room.id) }
    }
    @ViewBuilder private var content: some View {
        if let all = store.threadSummaries[room.id] {
            let shown = ThreadSummary.filtered(all, by: filters)
            if shown.isEmpty {
                ContentUnavailableView(all.isEmpty ? "No threads yet" : "All caught up", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(all.isEmpty ? "Threads with replies show here." : "No threads match these filters."))
            } else {
                List(shown) { thread in
                    Button { Task { await store.openThread(thread.head) } } label: { row(thread) }.buttonStyle(.plain)
                }.listStyle(.plain)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    /// The first message's text without custom emoji placeholders (U+FFFD), or what it carried when it has no text.
    static func preview(_ message: Message) -> String {
        let text = message.text.replacingOccurrences(of: "\u{FFFD}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (message.attachments.first?.name ?? "Attachment") : text
    }
    private func row(_ thread: ThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(thread.head.sender.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if thread.mentionsMe { Image(systemName: "at").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor) }
                if thread.unreadCount > 0 {
                    Text("\(thread.unreadCount)").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                }
            }
            Text(Self.preview(thread.head)).font(.callout).lineLimit(2)
            Text("\(thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies") · \(thread.lastReply.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}
