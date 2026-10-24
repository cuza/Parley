import ParleyDomain
import SwiftUI

/// A square media thumbnail; a play badge on videos.
struct Thumbnail: View {
    let attachment: Attachment
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    @State private var image: NSImage?
    var body: some View {
        Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .overlay {
                if attachment.kind == .video {
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white, .black.opacity(0.4))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
            .task(id: attachment) { image = try? await ImageCache.load(attachment, load) }
            .accessibilityLabel(attachment.name).accessibilityAddTraits(.isButton)
    }
}
