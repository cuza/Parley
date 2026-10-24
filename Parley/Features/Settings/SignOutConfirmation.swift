import SwiftUI

extension View {
    /// Asks before signing out, as General and Connection Diagnostics offer it; a failure shows in `error`, and `done`
    /// runs either way.
    func signOutConfirmation(
        isPresented: Binding<Bool>, store: ChatStore, signIn: SignInFlow?, error: Binding<String?>,
        done: @escaping () -> Void = {}
    ) -> some View {
        confirmationDialog("Sign out of Google Chat?", isPresented: isPresented) {
            Button("Sign Out", role: .destructive) {
                Task {
                    do {
                        try await signIn?.signOut()
                        store.signedOut()
                        error.wrappedValue = nil
                    } catch let failure { error.wrappedValue = failure.localizedDescription }
                    done()
                }
            }
        } message: {
            Text("Parley forgets this Google session and the messages it keeps on this Mac. Your drafts stay.")
        }
    }
}
