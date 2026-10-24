import AppKit
import ParleyDomain
import SwiftUI

/// A pending attachment above the field: a thumbnail for images, the file's icon otherwise, and a remove button.
struct PendingFileChip: View {
    @Environment(ChatStore.self) private var store
    let file: Attachment
    let conversation: Conversation
    var thread: ThreadID?
    var body: some View {
        HStack(spacing: 6) {
            PendingThumbnail(file: file)
            Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(
                maxWidth: 140, alignment: .leading)
            Button {
                store.detach(file, conversation: conversation.id, thread: thread)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(file.name)")
        }
        .padding(4).padding(.trailing, 4)
        .floatingGlass(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A file waiting in the composer: a picture's thumbnail, made once off the main thread (the composer redraws on every
/// keystroke, and reading a large photo there made typing stutter), or the file's icon.
struct PendingThumbnail: View {
    let file: Attachment
    @State private var picture: NSImage?
    private var path: String { file.url?.path(percentEncoded: false) ?? "" }
    var body: some View {
        Image(nsImage: picture ?? NSWorkspace.shared.icon(forFile: path))
            .resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
            .task(id: path) { if file.kind == .image, let url = file.url { picture = await Self.load(url) } }
    }
    /// 64 px on the longer side: the chip is 32 pt, on a Retina screen.
    nonisolated static func load(_ url: URL) async -> NSImage? {
        await Task.detached { (try? Data(contentsOf: url)).flatMap { ImageCache.decode($0, maxPixels: 64) } }.value
    }
}
