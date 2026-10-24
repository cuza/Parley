import ParleyDomain
import SwiftUI

/// An app's dialog in a sheet over the conversation, as Google Chat shows it: the title (the card's header, else the
/// app's name) with ✕, the card scrolling, and its own buttons fixed at the bottom. ✕ and Escape close it.
struct DialogSheet: View {
    let open: ChatStore.OpenDialog
    var width: CGFloat = DialogLayout.width
    var submit: (Data, [Card.Input]) async -> Void = { _, _ in }
    var cancel: () -> Void = {}
    @State private var expanded = false  // a collapsible section's "Show more"
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(open.dialog.title ?? open.app).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: cancel) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help("Close").accessibilityLabel("Close")
            }
            .padding(.horizontal, DialogLayout.margin).frame(height: DialogLayout.title)
            Divider()
            CardView(
                card: DialogLayout.card(open.dialog), expanded: expanded, toggle: { expanded.toggle() }, click: submit,
                footer: (open.dialog.primary, open.dialog.secondary), problem: open.problem
            )
            .id(open.dialog)  // the app's next step starts with its own values
        }
        .frame(width: width, height: DialogLayout.height(open, width: width, expanded: expanded))
    }
}

/// The dialog sheet's sizes: as tall as its card needs, up to `maxHeight`, then the card scrolls.
enum DialogLayout {
    static let width: CGFloat = 560, maxHeight: CGFloat = 640, margin: CGFloat = 20
    static let title: CGFloat = 44, footer: CGFloat = 56, problem: CGFloat = 36
    /// The dialog's card as the sheet draws it: no box of its own.
    static func card(_ dialog: AppDialog) -> Card {
        var card = dialog.card
        card.bare = true
        return card
    }
    static func height(_ open: ChatStore.OpenDialog, width: CGFloat, expanded: Bool = false) -> CGFloat {
        let body = CardLayout.boxHeight(card(open.dialog), width: width - 2 * margin, expanded: expanded) + 2 * margin
        return min(maxHeight, title + 1 + body + (open.problem == nil ? 0 : problem) + 1 + footer)
    }
}
