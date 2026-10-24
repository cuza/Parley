import ParleyDomain
import SwiftUI

/// A person in a list: their photo with their presence on its corner, their name over a caption (an email, a job
/// title), then what the row adds on the right. `prominent` is Settings' account row: a headline name and an email
/// that can be selected.
struct PersonRow<Trailing: View>: View {
    let name: String
    var caption: String?
    var avatarURL: URL?
    var size: CGFloat
    var presence: Presence?
    var isMe: Bool
    var external: Bool
    var prominent: Bool
    let trailing: Trailing
    init(
        _ name: String, caption: String? = nil, avatarURL: URL? = nil, size: CGFloat = 28, presence: Presence? = nil,
        isMe: Bool = false,
        external: Bool = false, prominent: Bool = false, @ViewBuilder trailing: () -> Trailing
    ) {
        self.name = name
        self.caption = caption
        self.avatarURL = avatarURL
        self.size = size
        self.presence = presence
        self.isMe = isMe
        self.external = external
        self.prominent = prominent
        self.trailing = trailing()
    }
    var body: some View {
        // Small avatars sit closer to the name, as the palette's other rows do.
        HStack(spacing: size < 28 ? 8 : 10) {
            Avatar(name: name, size: size, url: avatarURL)
                .overlay(alignment: .bottomTrailing) { PresenceDot(presence: presence, size: 8).offset(x: 2, y: 2) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(isMe ? "\(name) (you)" : name).font(prominent ? .headline : nil).lineLimit(1)
                    if external { ExternalBadge() }
                }
                if let caption {
                    if prominent {
                        Text(caption).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PersonRow where Trailing == EmptyView {
    init(
        _ name: String, caption: String? = nil, avatarURL: URL? = nil, size: CGFloat = 28, presence: Presence? = nil,
        isMe: Bool = false,
        external: Bool = false, prominent: Bool = false
    ) {
        self.init(
            name, caption: caption, avatarURL: avatarURL, size: size, presence: presence, isMe: isMe,
            external: external,
            prominent: prominent
        ) { EmptyView() }
    }
}

extension Person {
    /// Their email under their name, unless the name is the email.
    var emailCaption: String? { email == name ? nil : email }
}
