import SwiftUI

extension View {
    /// A keyboard shortcut with no control on screen and no menu item: Esc to close a pane wherever focus is, ⌘1 to ⌘9.
    /// SwiftUI gives key equivalents only to controls, so this is a button nobody sees, clicks or hears, behind the view.
    /// While `enabled` is false the key goes on to whatever else handles it.
    func hiddenShortcut(_ shortcut: KeyboardShortcut, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        background {
            if enabled {
                Button("", action: action).keyboardShortcut(shortcut).opacity(0).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
    func hiddenShortcut(
        _ key: KeyEquivalent, modifiers: EventModifiers = .command, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        hiddenShortcut(KeyboardShortcut(key, modifiers: modifiers), enabled: enabled, action: action)
    }
}
