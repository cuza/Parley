import AppKit
import ParleyDomain
import SwiftUI

/// The composer's formatting row, in web's toolbar order; the field's ComposerTextView is first responder and takes the
/// actions.
struct ComposerFormatBar: View {
    let composerHandle: ComposerHandle
    /// The colour at the field's selection, read by the composer as it redraws: the handle isn't observable.
    let currentColor: TextColor?
    @State private var colorPicker = false
    var body: some View {
        HStack(spacing: 2) {
            formatButton("bold", "Bold (⌘B)", #selector(ComposerTextView.formatBold(_:)))
            formatButton("italic", "Italic (⌘I)", #selector(ComposerTextView.formatItalic(_:)))
            formatButton("underline", "Underline (⌘U)", #selector(ComposerTextView.formatUnderline(_:)))
            // Web's colour button: an "A" underlined in the current colour, opening a row of dots.
            Button {
                colorPicker.toggle()
            } label: {
                Image(systemName: "character").overlay(alignment: .bottom) {
                    Capsule().fill(
                        currentColor.map {
                            Color(nsColor: NSColor(rgb: $0.argb & 0xFF_FFFF))
                        } ?? .secondary
                    )
                    .frame(width: 13, height: 2.5).offset(y: 3)
                }.frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless).help("Text color").accessibilityLabel("Text color")
            .popover(isPresented: $colorPicker, arrowEdge: .top) {
                ColorDots(current: currentColor) { color in
                    composerHandle.view?.color(color)
                    colorPicker = false
                    if let view = composerHandle.view { view.window?.makeFirstResponder(view) }
                }
            }
            formatButton(
                "strikethrough", "Strikethrough (⇧⌘X)", #selector(ComposerTextView.formatStrike(_:)))
            Divider().frame(height: 16)
            formatButton(
                "list.bullet", "Bulleted list (⇧⌘8)", #selector(ComposerTextView.formatList(_:)))
            Divider().frame(height: 16)
            formatButton("text.quote", "Quote (⌘')", #selector(ComposerTextView.formatQuote(_:)))
            formatButton("link", "Link (⇧⌘K)", #selector(ComposerTextView.formatLink(_:)))
            Divider().frame(height: 16)
            formatButton(
                "chevron.left.forwardslash.chevron.right", "Code (⇧⌘C)",
                #selector(ComposerTextView.formatCode(_:)))
            formatButton(
                "curlybraces.square", "Code block (⌥⇧⌘C)",
                #selector(ComposerTextView.formatCodeBlock(_:)))
        }
    }
    private func formatButton(_ icon: String, _ help: String, _ action: Selector) -> some View {
        Button {
            NSApp.sendAction(action, to: nil, from: nil)
        } label: {
            Image(systemName: icon).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
}

/// Web's text colour picker: the default colour, then its five, the current one checked.
struct ColorDots: View {
    let current: TextColor?
    let pick: (TextColor?) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach([nil] + TextColor.allCases.map(Optional.some), id: \.self) { (color: TextColor?) in
                Button {
                    pick(color)
                } label: {
                    Circle().fill(
                        color.map { Color(nsColor: NSColor(rgb: $0.argb & 0xFF_FFFF)) } ?? Color(nsColor: .textColor)
                    )
                    .overlay {
                        if color == current {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Self.check(on: color))
                        }
                    }
                    .overlay(Circle().stroke(.quaternary))
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).help(color?.name ?? "Default").accessibilityLabel(color?.name ?? "Default color")
            }
        }
        .padding(12)
    }
    /// A checkmark that shows on its dot: the default dot is the text colour (dark or light), amber is light.
    private static func check(on color: TextColor?) -> Color {
        switch color {
        case nil: Color(nsColor: .textBackgroundColor)
        case .amber?: .black
        default: .white
        }
    }
}
