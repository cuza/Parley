import SwiftUI

/// A side pane's header: Back when the pane steps back, its title, the pane's own buttons, then Close. The buttons are
/// borderless, with their names as tooltips and for VoiceOver.
struct PaneHeader<Accessories: View>: View {
    let title: String
    var back: (() -> Void)?
    var close: (() -> Void)?
    let accessories: Accessories
    init(
        _ title: String, back: (() -> Void)? = nil, close: (() -> Void)? = nil,
        @ViewBuilder accessories: () -> Accessories
    ) {
        self.title = title
        self.back = back
        self.close = close
        self.accessories = accessories()
    }
    var body: some View {
        HStack(spacing: 12) {
            if let back { Self.button("Back", icon: "chevron.left", back) }
            Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer()
            accessories
            if let close { Self.button("Close", icon: "xmark", close) }
        }.padding()
    }
    private static func button(_ name: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.borderless).help(name).accessibilityLabel(name)
    }
}

extension PaneHeader where Accessories == EmptyView {
    init(_ title: String, back: (() -> Void)? = nil, close: (() -> Void)? = nil) {
        self.init(title, back: back, close: close) { EmptyView() }
    }
}
