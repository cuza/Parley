import ParleyDomain
import SwiftUI

/// Who is typing, as Messages shows it: at the end of the conversation, the typist's picture beside a thought bubble whose
/// three dots pulse in turn, with their name over it outside a DM. Several typists share one bubble, their pictures
/// stacked. An app at work (Ask Gemini) says what it's doing in the bubble, its dots in its colours.
struct TypingBubble: View {
    let typists: [Person]
    var activity: String?  // an app's status, such as "Collecting info"
    var showsName = true
    var dots: [Color] = [.secondary, .secondary, .secondary]
    private var fill: Color { Color(nsColor: BubblePalette.incoming) }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .leading) {  // stacked, the first on top, as Messages stacks a group's pictures
                ForEach(Array(typists.prefix(3).enumerated().reversed()), id: \.element.id) { index, person in
                    Avatar(name: person.name, size: 28, url: person.avatarURL)
                        .overlay(
                            Circle().stroke(
                                Color(nsColor: .windowBackgroundColor), lineWidth: typists.count > 1 ? 2 : 0)
                        )
                        .offset(x: CGFloat(index) * 14)
                }
            }
            .frame(width: 28 + CGFloat(max(0, min(typists.count, 3) - 1)) * 14, alignment: .leading)  // level with the tail's end, as Messages draws it
            VStack(alignment: .leading, spacing: 3) {
                if showsName || typists.count > 1 {
                    // One typist's name in their colour, as the timeline writes it over their messages.
                    Text(Self.title(typists.map(\.name))).font(.caption.weight(.semibold))
                        .foregroundStyle(
                            typists.count == 1 && activity == nil
                                ? Color(nsColor: MessageRowView.color(for: typists[0].id.rawValue)) : .secondary
                        )
                        .padding(.leading, 12)
                }
                HStack(spacing: 10) {
                    TypingDots(colors: dots)
                    if let activity { Text("\(activity)…").font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
                .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                // The thought tail: two small circles trailing down to the picture.
                .background(alignment: .bottomLeading) {
                    ZStack(alignment: .bottomLeading) {
                        Circle().fill(fill).frame(width: 12, height: 12).offset(x: -3, y: 9)
                        Circle().fill(fill).frame(width: 6, height: 6).offset(x: -10, y: 15)
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            activity.map { "\(Self.title(typists.map(\.name))) · \($0)…" } ?? PresenceModel.typingLine(
                typists.map(\.name)) ?? "")
    }
    /// One typist by full name; two or three by first names; more as "Several people".
    nonisolated static func title(_ names: [String]) -> String {
        if names.count == 1 { return names[0] }
        if names.count > 3 { return "Several people" }
        return ListFormatter.localizedString(
            byJoining: names.map { String($0.split(separator: " ").first ?? Substring($0)) })
    }
}

/// Three dots that rise and brighten one after another; still with Reduce Motion.
struct TypingDots: View {
    var colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(colors[index % colors.count]).frame(width: 8, height: 8)
                    .opacity(reduceMotion ? 0.6 : up ? 1 : 0.35)
                    .offset(y: reduceMotion || !up ? 0 : -2)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever().delay(Double(index) * 0.15),
                        value: up)
            }
        }
        .onAppear { up = true }
    }
}
