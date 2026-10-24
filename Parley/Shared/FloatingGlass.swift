import SwiftUI

/// On macOS 26 the floating pieces are Liquid Glass and blend when close; earlier, material shapes.
struct FloatingGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
    }
}
extension View {
    /// A floating piece's background: Liquid Glass on macOS 26; earlier, a material with a hairline and a soft shadow.
    @ViewBuilder func floatingGlass(_ shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background { shape.fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.regularMaterial)) }
                .overlay(shape.stroke(.quaternary)).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }
    /// A small floating row above the composer's field.
    func floatingCapsule() -> some View {
        padding(.horizontal, 12).padding(.vertical, 6).floatingGlass(
            RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension ToolbarContent {
    /// A title is not a control: no glass capsule around it (macOS 26 gives every toolbar item one), as Messages shows the name.
    @ToolbarContentBuilder func titleWithoutGlass() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}
extension CustomizableToolbarContent {
    /// As above, for an item of a customizable toolbar.
    @ToolbarContentBuilder func titleWithoutGlass() -> some CustomizableToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}
