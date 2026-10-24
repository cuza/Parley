import ParleyDomain
import SwiftUI

/// A space's emoji, else its photo or image, else initials (people) or # (spaces). Circle for people, rounded square for spaces.
struct Avatar: View {
    let name: String
    var space = false
    var size: CGFloat = 24
    var url: URL?
    var emoji: String?
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale
    private var hue: Double { Self.hue(name) }
    nonisolated static func hue(_ name: String) -> Double {
        Double(name.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360
    }
    nonisolated static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: space ? size * 0.27 : size / 2) }
    var body: some View {
        ZStack {
            if let emoji {
                shape.fill(.quaternary)
                Text(emoji).font(.system(size: size * 0.62))
            } else if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                shape.fill(Color(hue: hue, saturation: 0.35, brightness: 0.55))  // white initials stay readable on it
                if space {
                    Image(systemName: "number").font(.system(size: size * 0.52, weight: .medium))
                } else {
                    Text(Self.initials(name)).font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                }
            }
        }.foregroundStyle(.white).frame(width: size, height: size).clipShape(shape).accessibilityHidden(true)
            .task(id: emoji == nil ? url : nil) {
                image = nil
                if emoji == nil, let url, let loaded = await RemoteImage.image(url, px: Int((size * scale).rounded())),
                    !Task.isCancelled
                {
                    image = loaded  // a cancelled load (the row was recycled) must not blank the newer avatar
                }
            }
    }
}
extension Avatar {
    /// A conversation's avatar: a space's emoji or image, else the DM's photo; `url` in place of the conversation's own.
    init(room: Conversation?, size: CGFloat, url: URL? = nil) {
        self.init(
            name: room?.name ?? "", space: room?.kind == .space, size: size, url: url ?? room?.avatarURL,
            emoji: room?.emoji)
    }
}
/// Green when active, a hollow ring when away, red when not to be disturbed; nothing while unknown.
struct PresenceDot: View {
    let presence: Presence?
    var size: CGFloat = 8
    var body: some View {
        switch presence {
        case .available:
            Circle().fill(.green).frame(width: size, height: size).overlay(Circle().stroke(.background, lineWidth: 1.5))
                .accessibilityLabel(Presence.available.title)
        case .away:
            Circle().strokeBorder(.secondary, lineWidth: 1.5).background(Circle().fill(.background)).frame(
                width: size, height: size
            ).accessibilityLabel(Presence.away.title)
        case .doNotDisturb:
            Circle().fill(.red).frame(width: size, height: size).overlay(Circle().stroke(.background, lineWidth: 1.5))
                .accessibilityLabel(Presence.doNotDisturb.title)
        case .offline, nil: EmptyView()
        }
    }
}
