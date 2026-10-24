import SwiftUI

/// An unread count in a sidebar or list row: white on the accent color.
struct UnreadPill: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 11, weight: .semibold, design: .rounded)).padding(.horizontal, 6).padding(
            .vertical, 2
        )
        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white).monospacedDigit().fixedSize()
    }
}

/// Google Chat's "External" mark: a conversation, or someone in it, from outside my organisation.
struct ExternalBadge: View {
    var body: some View {
        Text("External").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .help("Includes people outside your organization")
            .accessibilityLabel("External, includes people outside your organization")
    }
}
