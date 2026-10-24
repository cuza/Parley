import ParleyDomain
import SwiftUI

/// Settings ▸ General: account, sidebar, hidden conversations, GIPHY key.
struct GeneralSettings: View {
    @Environment(ChatStore.self) private var store
    @Environment(SignInFlow.self) private var signIn: SignInFlow?
    @State private var confirmSignOut = false
    @State private var accountError: String?
    @State private var giphyKey = Giphy.key ?? ""
    @State private var keyError: String?
    @AppStorage(SidebarLimit.enabledKey) private var limitSections = false
    @AppStorage(SidebarLimit.countKey) private var sectionLimit = 10
    var body: some View {
        Form {
            Section {
                if store.me.id.rawValue.isEmpty {
                    Text("Not signed in").foregroundStyle(.secondary)
                } else {
                    PersonRow(
                        store.me.name, caption: store.me.email, avatarURL: store.me.avatarURL, size: 36, prominent: true
                    ) {
                        Button("Sign Out…") { confirmSignOut = true }.disabled(signIn == nil)
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                if let accountError { SettingsFooter(accountError, color: .red) }
            }
            LoginItemSection()
            Section {
                Toggle("Limit sections", isOn: $limitSections)
                Picker("Rows per section", selection: $sectionLimit) {
                    ForEach(SidebarLimit.choices, id: \.self) { Text("\($0) rows").tag($0) }
                }
                .disabled(!limitSections)
            } header: {
                Text("Sidebar")
            } footer: {
                SettingsFooter(
                    "As in web Chat, each section shows its first rows, then Show all. Unread conversations and the open one always show."
                )
            }
            HiddenConversationsSection()
            Section {
                SecureField("GIPHY API key", text: $giphyKey)
                    .onChange(of: giphyKey) { _, key in
                        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try Giphy.setKey(key)
                            keyError = nil
                        } catch { keyError = error.localizedDescription }
                    }
            } footer: {
                SettingsFooter(
                    keyError
                        ?? "For the composer's GIF picker. Create one at developers.giphy.com. Parley keeps it in your Keychain.",
                    color: keyError == nil ? .secondary : .red)
            }
        }
        .signOutConfirmation(isPresented: $confirmSignOut, store: store, signIn: signIn, error: $accountError)
    }
}

/// "Open Parley at login", read from macOS each time Settings shows it, since it can change in System Settings too.
private struct LoginItemSection: View {
    @AppStorage(LaunchLanding.key) private var landing = LaunchLanding.home
    @State private var on = false
    @State private var needsApproval = false
    @State private var failure: String?
    private let item = LoginItem()
    var body: some View {
        Section {
            Toggle("Open Parley at login", isOn: $on)
                .onChange(of: on) { _, on in
                    guard on != item.isOn else { return }
                    do {
                        try item.set(on)
                        failure = nil
                    } catch { failure = error.localizedDescription }
                    read()
                }
            if needsApproval {
                LabeledContent {
                    Button("Open Login Items") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                } label: {
                    Text("macOS needs your approval in Login Items.").foregroundStyle(.orange)
                }
            }
            Picker("At launch, open", selection: $landing) {
                Text("Home").tag(LaunchLanding.home)
                Text("The last conversation").tag(LaunchLanding.last)
            }
        } footer: {
            if let failure { SettingsFooter(failure, color: .red) }
        }
        .onAppear(perform: read)
    }
    private func read() {
        on = item.isOn || item.needsApproval
        needsApproval = item.needsApproval
    }
}
