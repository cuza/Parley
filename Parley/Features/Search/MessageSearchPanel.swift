import ParleyDomain
import SwiftUI

/// Message search (⌘F).
struct MessageSearchPanel: View {
    /// What to search, carried by the sheet's item so the panel never opens with a stale scope: ⌘F's conversation
    /// starts as the "said in" filter, which can be changed or cleared like any other.
    struct Request: Identifiable {
        var id = UUID()
        let scope: Conversation?
        var query = ""
    }
    @Environment(ChatStore.self) private var store
    @State private var query: String
    @State private var filters: SearchFilters
    init(scope: Conversation? = nil, query: String = "") {
        _query = State(initialValue: query)
        _filters = State(initialValue: SearchFilters(saidIn: scope.map { [$0.id] } ?? []))
    }
    @State private var selected: MessageID?
    @State private var searching = false
    @Environment(\.dismiss) private var dismiss
    private struct Ask: Equatable {
        var query: String
        var filters: SearchFilters
    }
    /// What the list shows when it has no results: a prompt before anything is asked, progress, or that nothing matched.
    @ViewBuilder private var noResults: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty && filters.isEmpty {
            ContentUnavailableView(
                "Search messages", systemImage: "magnifyingglass",
                description: Text("Type words, or pick a person, a conversation or a date."))
        } else if searching {
            ProgressView()
        } else {
            ContentUnavailableView.search(text: query)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            TextField("Search messages", text: $query).textFieldStyle(.plain).font(.title3).padding(.horizontal, 18)
                .padding(.top, 18)
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }  // through the results without leaving the field
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .padding(.bottom, 10).onSubmit { choose() }
            SearchChips(filters: $filters).padding(.horizontal, 18).padding(.bottom, 10)
            Divider()
            List(selection: $selected) {
                ForEach(store.searchResults) { message in
                    SearchResultRow(
                        message: message,
                        conversation: store.rooms.conversations.first { $0.id == message.conversationID }?.name
                            ?? "Conversation",
                        load: { try await store.attachmentData($0, thumbnail: $1) }
                    )
                    .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())  // the whole row opens it
                    .tag(message.id).onTapGesture {
                        selected = message.id
                        choose()
                    }
                }
            }.frame(height: 280)
                .overlay { if store.searchResults.isEmpty { noResults } }
            HStack {
                Text("Searches Google Chat").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }.frame(width: 500)
            .task(id: Ask(query: query, filters: filters)) {
                guard await TypingPause.ended() else { return }
                searching = true
                defer { searching = false }
                await store.search(query, filters: filters)
                selected = store.searchResults.first?.id
            }
    }
    private func move(_ step: Int) {
        let ids = store.searchResults.map(\.id)
        guard !ids.isEmpty else { return }
        let at = selected.flatMap(ids.firstIndex) ?? (step > 0 ? -1 : ids.count)
        selected = ids[min(max(at + step, 0), ids.count - 1)]
    }
    private func choose() {
        guard let selected else { return }
        Task {
            if let message = store.searchResults.first(where: { $0.id == selected }) { await store.jump(message) }
            dismiss()
        }
    }
}

/// A search result as Google Chat's web draws it: who and where, the text, then what the message carries. Pictures show
/// as thumbnails and files and Drive links by name, so a picture or a document can be found by sight.
struct SearchResultRow: View {
    let message: Message
    let conversation: String
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    static let thumbnail: CGFloat = 56
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.sender.name, size: 28, url: message.sender.avatarURL)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(message.sender.name) · \(conversation)").font(.caption).foregroundStyle(.secondary)
                if !message.text.isEmpty { Text(message.text).lineLimit(3) }
                let shown = Self.shown(message.attachments)
                if !shown.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, attachment in item(attachment) }
                    }
                }
            }
        }
    }
    /// Cards and calls are not things to find.
    static func shown(_ attachments: [Attachment]) -> [Attachment] {
        attachments.filter { $0.kind != .card && $0.kind != .call }
    }
    /// A link's symbol, by the Drive file it opens, or a voice message's; nil for a file, which shows the Finder's icon for its type.
    static func symbol(_ attachment: Attachment) -> String? {
        if attachment.kind == .voice { return "waveform" }
        guard attachment.kind == .link else { return nil }
        let kind = attachment.contentType + (attachment.url?.path() ?? "")
        return kind.contains("document")
            ? "doc.text"
            : kind.contains("spreadsheet")
                ? "tablecells"
                : kind.contains("presentation") ? "rectangle.on.rectangle" : "link"
    }
    @ViewBuilder private func item(_ attachment: Attachment) -> some View {
        if attachment.kind == .image || attachment.kind == .video {
            Thumbnail(attachment: attachment, load: load).frame(width: Self.thumbnail, height: Self.thumbnail)
        } else {
            HStack(spacing: 5) {
                if let symbol = Self.symbol(attachment) {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: attachment.utType ?? .data)).resizable().frame(
                        width: 16, height: 16)
                }
                Text(attachment.kind == .voice ? "Voice message" : attachment.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .help(attachment.name)
        }
    }
}
