import AppKit
import ParleyDomain
import SwiftUI

/// The info panel's last section: the media, files or links the conversation shares, picked by the segmented control
/// in its header, with how to load more in its footer.
struct SharedContentSection: View {
    @Environment(ChatStore.self) private var store
    let room: Conversation
    @Binding var tab: SharedCategory
    let files: AttachmentFiles
    var body: some View {
        Section {
            shared
        } header: {
            Picker("Shared", selection: $tab) { ForEach(SharedCategory.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden()
        } footer: {
            footer
        }
    }
    @ViewBuilder private var shared: some View {
        let items = self.items
        if items.isEmpty {
            Text("No \(tab.rawValue.lowercased())").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if tab == .media {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 4)], spacing: 4) {
                ForEach(items) { item in
                    Thumbnail(attachment: item.attachment, load: files.load)
                        .onTapGesture { files.preview(item.attachment) }
                        .contextMenu { showInChat(item) }
                        .help(
                            "\(item.attachment.name) · \(item.sender), \(item.date.formatted(date: .abbreviated, time: .shortened))"
                        )
                }
            }
        } else {
            ForEach(items) { item in
                Button {
                    item.attachment.kind == .link ? open(item.attachment) : files.preview(item.attachment)
                } label: {
                    row(item)
                }.buttonStyle(.plain)
                    .contextMenu { showInChat(item) }
            }
        }
    }
    /// Right-click on a shared item: go to the message that shared it.
    @ViewBuilder private func showInChat(_ item: SharedContent.Item) -> some View {
        if item.messageID != nil { Button("Show in Chat") { Task { await store.showShared(item, in: room.id) } } }
    }
    private func open(_ link: Attachment) { if let url = link.url { NSWorkspace.shared.open(url) } }
    private func row(_ item: SharedContent.Item) -> some View {
        HStack(spacing: 10) {
            Image(
                nsImage: item.attachment.kind == .link
                    ? NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
                    : NSWorkspace.shared.icon(for: item.attachment.utType ?? .data)
            )
            .resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.attachment.name).lineLimit(1).truncationMode(.middle)
                Text(
                    "\(item.attachment.kind == .link ? item.attachment.url?.host() ?? "" : item.attachment.detail) · \(item.sender), \(item.date.formatted(date: .abbreviated, time: .omitted))"
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle()).help(item.attachment.url?.absoluteString ?? item.attachment.name)
    }
    /// The server's list of what the conversation shares; until it arrives (or if it fails), what loaded messages share.
    private var fromServer: [SharedContent.Item]? { store.rooms.shared[store.sharedKey(room.id, tab)] }
    private var items: [SharedContent.Item] {
        if let fromServer { return fromServer }
        let content = SharedContent(store.history.messages.filter { $0.conversationID == room.id })
        return switch tab {
        case .media: content.media
        case .files: content.files
        case .links: content.links
        }
    }
    @ViewBuilder private var footer: some View {
        if fromServer != nil {
            if store.rooms.sharedMore.contains(store.sharedKey(room.id, tab)) {
                HStack {
                    Spacer()
                    Button("Load more") { Task { await store.loadShared(tab, in: room.id, more: true) } }.buttonStyle(
                        .link)
                }.font(.caption)
            }
        } else {
            HStack {
                Text("From loaded messages")
                Spacer()
                if store.history.loading.contains(store.key(room.id, nil)) {
                    ProgressView().controlSize(.small)
                } else if store.history.hasMore.contains(store.key(room.id, nil)) {
                    Button("Load older") { Task { await store.loadOlderIfNeeded(room.id) } }.buttonStyle(.link)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
