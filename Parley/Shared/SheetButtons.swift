import SwiftUI

extension View {
    /// A sheet's Cancel and primary buttons, in the toolbar places macOS keeps for them: Cancel answers Esc, and the
    /// primary button is the default one, which Return presses. A sheet adds a leading button (Delete) with
    /// `ToolbarItem(placement: .destructiveAction)`.
    func sheetButtons(
        _ title: String, role: ButtonRole? = nil, enabled: Bool = true, cancel: @escaping () -> Void,
        confirm: @escaping () -> Void
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel, action: cancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button(title, role: role, action: confirm).disabled(!enabled)
            }
        }
    }
}
