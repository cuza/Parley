import SwiftUI

/// A person's detailed view in the side pane, as Google Chat opens it from their card: who they are, their reporting
/// line, and what we recently shared, from Google Contacts. A report or manager opens theirs; Back steps back.
struct PersonDetailsPane: View {
    @Bindable var store: ChatStore
    @Environment(\.paneWindow) private var paneWindow
    @Environment(\.openURL) private var openURL
    let person: Person
    /// Colleagues opened from here, the last one showing.
    @State private var trail: [PersonDetails.Colleague] = []
    @State private var card = PersonCardDetails()
    @State private var details: PersonDetails?
    @State private var loading = true
    /// What this pane already loaded, by person, so Back shows it again without asking.
    @State private var loaded: [PersonID: (card: PersonCardDetails, details: PersonDetails?)] = [:]

    private var shown: Person {
        trail.last.map { Person(id: $0.id, name: $0.name, avatarURL: $0.avatarURL) } ?? person
    }
    private var title: String? { card.title ?? trail.last?.title }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("Back").accessibilityLabel("Back")
                Text("Details").font(.headline)
                Spacer()
            }.padding()
            Divider()
            form
        }
        .task(id: shown.id) {
            let person = shown
            if let known = loaded[person.id] { (card, details, loading) = (known.card, known.details, false); return }
            loading = true; card = PersonCardDetails(); details = nil
            async let found = store.cardDetails(of: person)
            details = await store.personDetails(of: person)
            card = await found
            loading = false
            loaded[person.id] = (card, details)
        }
    }
    private func back() {
        if trail.isEmpty { store.setPane(paneWindow) { $0.person = nil } } else { trail.removeLast() }
    }

    private var form: some View {
        Form {
            Section { header }
            Section {
                HStack {
                    if shown.id != store.me.id {
                        InfoPanel.action("Message", icon: "bubble.left", help: "Message \(shown.name)") {
                            Task { do { try await store.message([shown]) } catch { store.report(error) } }
                        }
                    }
                    if let email = shown.email, let mail = URL(string: "mailto:\(email)") {
                        InfoPanel.action("Email", icon: "envelope", help: "Send an email to \(shown.name)") { openURL(mail) }
                    }
                }
            }
            if let email = shown.email {
                Section("Contact details") {
                    LabeledContent("Email") { Text(email).textSelection(.enabled) }
                }
            }
            if let details {
                if !details.reports.isEmpty {
                    Section(details.reportCount == 1 ? "1 direct report" : "\(details.reportCount) direct reports") {
                        ForEach(details.reports) { colleague($0) }
                    }
                }
                if !details.managers.isEmpty { Section("Management chain") { ForEach(details.managers) { colleague($0) } } }
                if !details.recent.isEmpty { Section("Recent interactions") { ForEach(details.recent, id: \.self) { item($0) } } }
                if !details.files.isEmpty {
                    Section {
                        ForEach(details.files, id: \.self) { item($0) }
                    } header: { Text("Shared files") } footer: {
                        if let more = details.moreFiles { Link("Open Google Drive", destination: more) }
                    }
                }
            } else if loading {
                Section { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            } else {
                Section { Text("Google Contacts has no more details for \(shown.name).").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onExitCommand(perform: back)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Avatar(name: shown.name, size: 72, url: shown.avatarURL)
            Text(shown.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            if let title { Text(title).foregroundStyle(.secondary) }
            if let zone = card.timeZone { LocalTimeLabel(zone: zone, name: shown.name).font(.callout) }
        }.frame(maxWidth: .infinity).padding(.vertical, 6)
    }
    /// Someone in their reporting line: a click opens their details here.
    private func colleague(_ colleague: PersonDetails.Colleague) -> some View {
        Button { trail.append(colleague) } label: {
            HStack(spacing: 10) {
                Avatar(name: colleague.name, size: 28, url: colleague.avatarURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(colleague.name).lineLimit(1)
                    if let title = colleague.title { Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help("Show \(colleague.name)’s details")
    }
    /// An event, email or file: opens in the browser.
    private func item(_ item: PersonDetails.Item) -> some View {
        Button { openURL(item.url) } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(item.kind)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(2)
                    if let date = item.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(item.url.host() ?? "")
        .contextMenu {
            Button("Copy Link") { ChatLink.copy(item.url) }
        }
    }
    static func symbol(_ kind: PersonDetails.Item.Kind) -> String {
        switch kind { case .event: "calendar"; case .email: "envelope"; case .file: "doc" }
    }
}
