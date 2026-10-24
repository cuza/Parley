import ParleyDomain
import SwiftUI

/// The top of the composer's field while it edits a message, or replies to or forwards one; nothing otherwise.
struct ComposerFieldHeader: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.paneWindow) private var paneWindow  // which window's side pane this view acts on
    let conversation: Conversation
    var thread: ThreadID?
    private var scope: String { store.key(conversation.id, thread) }
    var body: some View {
        if let editing = store.editingID(conversation.id, thread: thread).flatMap({ id in
            store.history.messages.first { $0.id == id }
        }) {
            editHeader(editing)
        } else if let quote = store.drafting.quoting[scope] {
            quoteHeader(quote)
        }
    }
    /// The reply or forward inside the field, as Telegram shows it: an accent bar, who, and one line of the message.
    private func quoteHeader(_ quote: QuotedMessage) -> some View {
        accessoryHeader(
            title: quote.forwardedFrom == nil ? "Reply to \(quote.sender)" : "Forward from \(quote.sender)",
            text: quote.text, media: quote.media,
            closeHelp: quote.forwardedFrom == nil ? "Cancel reply" : "Cancel forward",
            close: { store.drafting.quoting[scope] = nil },
            show: {
                guard let id = quote.id else { return }
                Task {
                    if !id.rawValue.hasPrefix(conversation.id.rawValue + "/"), let url = ChatLink.url(message: id),
                        let link = ChatLink(url)
                    {
                        _ = await store.open(link)
                    } else {
                        await store.showQuoted(id, in: conversation.id, window: paneWindow)
                    }
                }
            })
    }
    /// Telegram's edit panel: the message being edited, one line; its attachments stay, as in Google Chat.
    private func editHeader(_ message: Message) -> some View {
        accessoryHeader(
            title: "Edit message",
            text: QuotedMessage.summary(
                text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments),
            media: message.attachments.first { $0.kind == .image || $0.kind == .video }, closeHelp: "Cancel editing",
            close: { store.endEdit(conversation: conversation.id, thread: thread) }
        ) {
            Task { await store.showQuoted(message.id, in: conversation.id, window: paneWindow) }
        }
    }
    private func accessoryHeader(
        title: String, text: String, media: Attachment?, closeHelp: String, close: @escaping () -> Void,
        show: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color.accentColor).frame(width: 3)
            if let media {
                Thumbnail(attachment: media, load: { try await store.attachmentData($0, thumbnail: $1) }).frame(
                    width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor).lineLimit(1)
                Text(text).font(.callout).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: show)  // as in Telegram, a click shows the message
            .help("Show the message")
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("\(closeHelp) (Esc)").accessibilityLabel(closeHelp)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 14).padding(.trailing, 16).padding(.top, 10)
    }
}
