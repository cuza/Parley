import AppKit
import ParleyDomain
import SwiftUI
import UniformTypeIdentifiers

/// One attachment in a bubble: images, GIFs and video posters inline; files and links as a chip.
/// `load(attachment, thumbnail)` returns the bytes (`ChatStore.attachmentData`). Clicks, drags and the menu are
/// handled by the row's `AttachmentHostView`.
struct AttachmentView: View {
    let attachment: Attachment
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    var own = false  // in my bubble: a voice message draws in my bubble's text colour
    var transcriptOpen = false
    var toggleTranscript: () -> Void = {}
    var dismissCard: () -> Void = {}
    var clickCard: (String?, Data, [Card.Input]) async -> Void = { _, _, _ in }
    var corners: RowLayout.Corners?  // a picture filling its bubble: the corners at the bubble's (the others are small)
    @State private var loaded: (key: String, image: NSImage)?
    @State private var failedKey: String?
    /// The row view is recycled: only this attachment's picture or failure shows, and a cached picture shows on the
    /// first frame, without a placeholder in between.
    private var image: NSImage? { loaded?.key == key ? loaded?.image : ImageCache.cached(attachment) }
    private var failed: Bool { failedKey == key }
    private var key: String { ImageCache.key(attachment) }

    var body: some View {
        if attachment.kind == .voice {
            VoiceMessageView(
                attachment: attachment, own: own, load: load, transcriptOpen: transcriptOpen,
                toggleTranscript: toggleTranscript)
        } else if let card = attachment.card {
            CardView(
                card: card, dismiss: dismissCard, expanded: transcriptOpen, toggle: toggleTranscript,
                click: { await clickCard(card.id, $0, $1) }
            )
            .id(attachment.cacheKey)
        }  // a recycled row starts with empty fields
        else if attachment.kind == .image || attachment.kind == .video {
            media
        } else if attachment.domain != nil {
            card
        } else {
            chip
        }
    }

    /// Link preview: image on top, cropped to fill; then title, snippet and domain.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.quaternary).frame(height: cardImageHeight)
                .overlay(alignment: .top) {  // top-aligned: a document preview shows its first lines
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                    } else if failed {  // as Google Chat shows a file it can't preview (no access): its type's icon, large
                        Image(systemName: driveSymbol ?? "link").font(.system(size: driveSymbol == nil ? 13 : 56))
                            .foregroundStyle(own ? ink.opacity(0.8) : Color.secondary).frame(maxHeight: .infinity)
                    }
                }
                .overlay {
                    if attachment.isVideoLink {
                        Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(
                            .white, .black.opacity(0.5))
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(failed && attachment.untitledDrive ? "You don't have access to this file" : attachment.name).font(
                    .callout.weight(.semibold)
                ).lineLimit(2).foregroundStyle(text(.primary, 1))
                if let snippet = attachment.snippet, snippet != attachment.name {
                    Text(snippet).font(.caption).foregroundStyle(text(.secondary, 0.8)).lineLimit(2)
                }
                Text(attachment.domain ?? "").font(.caption2).foregroundStyle(text(.tertiary, 0.65)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)  // the row sizes it (RowLayout.attachmentSize)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .help(attachment.url?.absoluteString ?? attachment.name)
        .task(id: attachment) { await loadThumbnail() }
    }
    private func radius(_ corner: RowLayout.Corners) -> CGFloat {
        corners.map { $0.contains(corner) ? RowLayout.mediaRadius : RowLayout.mediaInnerRadius }
            ?? RowLayout.mediaRadius
    }
    private var cardImageHeight: CGFloat { attachment.cardImageHeight }
    private var media: some View {
        ZStack {
            if let image {
                MediaPicture(image: image).transition(.opacity)
            } else {
                Rectangle().fill(.quaternary)
                if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if attachment.kind == .video {
                Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(
                    .white, .black.opacity(0.6))
            }
        }
        .overlay(alignment: .topLeading) {  // Telegram's badge on an animated picture, on one taller than 80
            GeometryReader { geometry in
                if attachment.contentType == "image/gif", geometry.size.height > 80 {
                    Text("GIF").font(.system(size: 10)).foregroundStyle(.white).padding(.horizontal, 6).padding(
                        .vertical, 3
                    )
                    .background(.black.opacity(0.6), in: Capsule()).padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // the row sizes it: mediaSize, narrowed to fit the bubble
        // Circular, as the bubble's arcs: a continuous corner is rounder and leaves a sliver of the bubble.
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: radius(.topLeft), bottomLeadingRadius: radius(.bottomLeft),
                bottomTrailingRadius: radius(.bottomRight), topTrailingRadius: radius(.topRight), style: .circular)
        )
        .overlay {  // a hairline round a picture with no bubble: a white picture would melt into a white background
            if corners == nil {
                RoundedRectangle(cornerRadius: RowLayout.mediaRadius, style: .circular).strokeBorder(
                    Color.primary.opacity(0.15), lineWidth: 1)
            }
        }
        .help(attachment.name)
        .task(id: attachment) { await loadThumbnail() }
    }

    private var chip: some View {
        HStack(spacing: 8) {
            if attachment.kind == .call {  // as Google Chat shows a call: a video icon, red when missed
                Image(systemName: attachment.call == .missed ? "video.slash.fill" : "video.fill").font(
                    .system(size: 18)
                )
                .foregroundStyle(attachment.call == .missed ? Color.red : own ? ink : Color.secondary).frame(
                    width: 28, height: 28)  // my bubble's text colour on it bubble
            } else if let driveSymbol {
                Image(systemName: driveSymbol).font(.system(size: 20)).foregroundStyle(text(.secondary, 0.9)).frame(
                    width: 28, height: 28)
            } else {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1).truncationMode(.middle).foregroundStyle(text(.primary, 1))
                Text(detail).font(.caption).foregroundStyle(text(.secondary, 0.8)).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 280, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .help(attachment.url?.absoluteString ?? attachment.name)
    }
    private var type: UTType? { attachment.utType }
    /// Card and chip background: set off from my bubble so its text stands out; a light tint elsewhere.
    private var fill: AnyShapeStyle {
        own ? AnyShapeStyle(Color(nsColor: BubblePalette.ownWell)) : AnyShapeStyle(.quaternary.opacity(0.6))
    }
    /// Card and chip text: my bubble's text colour on it, the system's levels elsewhere.
    private var ink: Color { Color(nsColor: BubblePalette.ownInk) }
    private func text(_ level: HierarchicalShapeStyle, _ white: Double) -> AnyShapeStyle {
        own ? AnyShapeStyle(ink.opacity(white)) : AnyShapeStyle(level)
    }
    /// Google Docs, Sheets and Slides have no system file type: a symbol for each, and a page for other Drive-native files.
    private var driveSymbol: String? {
        let type = attachment.contentType
        guard type.hasPrefix("application/vnd.google-apps") || attachment.untitledDrive else { return nil }
        // Google Chat sends the editors' own names: kix (Docs), ritz (Sheets), punch (Slides).
        return type.hasSuffix(".spreadsheet") || type.hasSuffix(".ritz")
            ? "tablecells.fill"
            : type.hasSuffix(".presentation") || type.hasSuffix(".punch")
                ? "rectangle.on.rectangle.angled.fill" : "doc.fill"
    }
    private var icon: NSImage {
        if attachment.kind == .link && type == nil {
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(for: type ?? .data)
    }
    private var detail: String { attachment.detail }

    /// Fetches and decodes the picture unless it is cached; one that had to load fades in (0.2 s, as Telegram).
    private func loadThumbnail() async {
        let key = self.key
        guard image == nil else { return }
        do {
            guard let decoded = try await ImageCache.load(attachment, load) else {
                failedKey = key
                return
            }
            withAnimation(.easeIn(duration: 0.2)) { loaded = (key, decoded) }
        } catch { if !(error is CancellationError) { failedKey = key } }
    }
}

/// Sizes `AttachmentView` draws at, known before any bytes load; `RowLayout` reserves the same.
extension Attachment {
    /// Known image size scaled to the 320-pt card width, capped so a tall image doesn't dominate the row.
    var cardImageHeight: CGFloat {
        guard let imageWidth = width, let imageHeight = height else { return 160 }
        return min(180, max(80, 320 * CGFloat(imageHeight) / CGFloat(imageWidth)))
    }
    /// Fits the known size into 320×240 so the row keeps its height while the bytes load.
    var mediaSize: CGSize {
        let imageWidth = CGFloat(width ?? 320)
        let imageHeight = CGFloat(height ?? 240)
        let scale = min(1, 320 / imageWidth, 240 / imageHeight)
        return CGSize(width: max(60, imageWidth * scale).rounded(), height: max(60, imageHeight * scale).rounded())  // whole points, so edges land on pixels
    }
    var utType: UTType? { UTType(mimeType: contentType) }
    // ponytail: the wire has no byte size; the chip shows the kind instead.
    /// A link to a video (YouTube), drawn with a play button over its picture.
    var isVideoLink: Bool { kind == .link && domain == "youtube.com" }
    var detail: String {
        if contentType == Self.calendarType { return "Google Calendar" }
        if contentType == Self.taskType { return "Google Tasks" }
        return kind == .call
            ? "Google Meet" : kind == .link ? url?.host() ?? "Link" : utType?.localizedDescription ?? "File"
    }
}

extension Attachment {
    // ponytail: a card is cropped to fill 320 pt wide, so 640 pt covers all but extreme panoramas.
    /// The longer side, in pixels, that the timeline draws this picture at: the media frame, or the link card,
    /// on the sharpest screen attached.
    @MainActor var displayPixels: Int {
        let points = kind == .image || kind == .video ? max(mediaSize.width, mediaSize.height) : 640
        return Int(points * (NSScreen.screens.map(\.backingScaleFactor).max() ?? 2))
    }
}
