import ParleyDomain
import SwiftUI

/// What the ⌘K / New Chat palette lists for a query: matching conversations, then people without a listed DM
/// (and not already picked for a group DM), then directory spaces not in the sidebar.
struct PaletteResults {
    enum Item: Hashable, Identifiable {
        case conversation(Conversation)
        case person(Person)
        case space(SpaceListing)
        case link(URL)
        var id: String {
            switch self {
            case .link(let url): "l:" + url.absoluteString
            case .conversation(let room): "c:" + room.id.rawValue
            case .person(let person): "p:" + person.id.rawValue
            case .space(let space): "s:" + space.id.rawValue
            }
        }
    }
    let conversations: [Conversation]
    let people: [Person]
    let invitations: [SpaceListing]  // spaces someone invited me to, shown before people
    let link: URL?  // a pasted Google Chat link, offered first
    let spaces: [SpaceListing]
    init(query: String, conversations: [Conversation], people: [Person], spaces: [SpaceListing], picked: [Person]) {
        let query = query.trimmingCharacters(in: .whitespaces)
        link = URL(string: query).flatMap { ChatLink($0) == nil ? nil : $0 }
        func matches(_ text: String?) -> Bool { query.isEmpty || text?.localizedCaseInsensitiveContains(query) == true }
        self.conversations = conversations.filter { matches($0.name) }
        let listedDMs = Set(self.conversations.filter { $0.kind == .direct }.flatMap(\.members).map(\.id))
        let pickedIDs = Set(picked.map(\.id))
        self.people = people.filter {
            !listedDMs.contains($0.id) && !pickedIDs.contains($0.id) && (matches($0.name) || matches($0.email))
        }
        let inSidebar = Set(conversations.map(\.id))
        let open = spaces.filter { !$0.joined && !inSidebar.contains($0.id) && matches($0.name) }
        // Invitations get their own section above people, so the sidebar's invitation row opens onto them.
        invitations = open.filter(\.invited)
        self.spaces = open.filter { !$0.invited }
    }
    var items: [Item] {
        (link.map { [Item.link($0)] } ?? []) + conversations.map(Item.conversation) + invitations.map(Item.space)
            + people.map(Item.person) + spaces.map(Item.space)
    }
}

/// ⌘K jumps to a conversation, or finds someone to message or a space to join. `newChat` (⌘N, the sidebar's
/// compose button) lists known people and the space directory before anything is typed.
struct ConversationPalette: View {
    @Environment(ChatStore.self) private var store
    var newChat = false
    var then: ((ConversationID) -> Void)?  // after opening the pick: Forward… leaves the message there
    var thenPrompt = "Forward to a conversation or person"  // the field's prompt when `then` is set
    var here: ((ConversationID) -> Void)?  // a new tab's palette: the pick opens in that tab, not the main window
    @State private var query = ""
    @State private var selected: String?
    @State private var people: [Person] = []
    @State private var spaces: [SpaceListing] = []
    @State private var picked: [Person] = []  // a group DM in the making
    @State private var searching = false
    @State private var working = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool  // a sheet focuses its field on its own; a new tab's window doesn't
    private var results: PaletteResults {
        PaletteResults(
            query: query, conversations: newChat && query.isEmpty ? [] : store.rooms.conversations, people: people,
            spaces: spaces, picked: picked)
    }
    private func spaceRow(_ space: SpaceListing) -> some View {
        row(.space(space)) {
            Avatar(name: space.name, space: true, size: 22, url: space.avatarURL, emoji: space.emoji)
            VStack(alignment: .leading, spacing: 1) {
                Text(space.name).lineLimit(1)
                if let detail = SpaceListing.detail(space) {
                    Text(detail).font(.caption).foregroundStyle(space.invited ? Color.accentColor : .secondary)
                }
            }
            Spacer(minLength: 0)
            Text("Join").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(picked) { person in
                    HStack(spacing: 3) {
                        Text(person.name).lineLimit(1)
                        Button {
                            picked.removeAll { $0.id == person.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(person.name)")
                    }.font(.callout).padding(.horizontal, 7).padding(.vertical, 3).background(
                        .quaternary, in: Capsule())
                }
                TextField(
                    then != nil
                        ? thenPrompt
                        : newChat || !picked.isEmpty
                            ? "Name or email, or a space to join" : "Jump to a conversation, person or space",
                    text: $query
                )
                .textFieldStyle(.plain).font(.title3).onSubmit { choose() }
                .focused($typing).onAppear { DispatchQueue.main.async { typing = true } }  // once the window is key
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                if searching || working { ProgressView().controlSize(.small) }
            }.padding(18)
            Divider()
            List(selection: $selected) {
                let results = results
                if let link = results.link {
                    Section("Link") {
                        row(.link(link)) {
                            Image(systemName: "link").frame(width: 22)
                            Text(Self.linkTitle(link, in: store.rooms.conversations)).lineLimit(1)
                        }
                    }
                }
                if !results.conversations.isEmpty {
                    Section("Conversations") {
                        ForEach(results.conversations) { room in
                            row(.conversation(room)) {
                                Avatar(room: room, size: 22)
                                Text(room.name).lineLimit(1)
                            }
                        }
                    }
                }
                if !results.invitations.isEmpty {
                    Section("Invitations") { ForEach(results.invitations) { spaceRow($0) } }
                }
                if !results.people.isEmpty {
                    Section("People") {
                        ForEach(results.people) { person in
                            row(.person(person)) {
                                PersonRow(
                                    person.name, caption: person.emailCaption, avatarURL: person.avatarURL, size: 22
                                ) {
                                    Button {
                                        pick(person)
                                    } label: {
                                        Image(systemName: "plus.circle")
                                    }.buttonStyle(.borderless)
                                        .help("Add to a group message (⌘Return)").accessibilityLabel(
                                            "Add \(person.name) to a group message")
                                }
                            }
                        }
                    }
                }
                if !results.spaces.isEmpty {
                    Section(newChat ? "Browse spaces" : "Spaces") { ForEach(results.spaces) { spaceRow($0) } }
                }
            }.frame(height: here == nil ? 320 : nil).frame(maxHeight: .infinity)  // a new tab's fills the window
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 8)
            }
            HStack {
                Text(
                    picked.isEmpty
                        ? "↑↓ to choose · Return to open · ⌘Return to add someone"
                        : "⌘Return to add someone · Return to message the group"
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if newChat {
                    Button("New Space…") {
                        dismiss()
                        store.newSpaceRequests += 1
                    }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(
                    picked.isEmpty ? "Open" : "Message \(picked.count == 1 ? picked[0].name : "\(picked.count) people")"
                ) { choose() }
                .keyboardShortcut(.defaultAction).disabled(working)
            }.padding(12)
                // ⌘Return wherever focus is, in the field or the list, as the hint says.
                .hiddenShortcut(.return) { if case .person(let person)? = current { pick(person) } }
        }.frame(width: here == nil ? 520 : nil)
            .task(id: query) {
                problem = nil
                let text = query.trimmingCharacters(in: .whitespaces)
                guard newChat || !text.isEmpty else {
                    people = []
                    spaces = []
                    selected = results.items.first?.id
                    return
                }
                selected = results.items.first?.id
                guard results.link == nil else { return }  // a pasted link isn't a name to search for
                guard await TypingPause.ended() else { return }
                searching = true
                defer { searching = false }
                async let foundPeople = store.searchPeople(matching: text)
                async let foundSpaces = store.searchSpaces(matching: text)
                do { people = try await foundPeople } catch {
                    people = []
                    problem = error.localizedDescription
                }
                do { spaces = try await foundSpaces } catch {
                    spaces = []
                    problem = problem ?? error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                if selected == nil || !results.items.contains(where: { $0.id == selected }) {
                    selected = results.items.first?.id
                }
            }
    }
    private func row(_ item: PaletteResults.Item, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }.padding(.vertical, 2).contentShape(Rectangle()).tag(item.id)
            .onTapGesture {
                selected = item.id
                choose()
            }
    }
    private var current: PaletteResults.Item? { results.items.first { $0.id == selected } }
    private func move(_ step: Int) {
        let items = results.items
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selected }.map { $0 + step } ?? 0
        selected = items[min(max(index, 0), items.count - 1)].id
    }
    private func pick(_ person: Person) {
        picked.append(person)
        query = ""
    }
    private func choose() {
        let item = current
        guard !working, !picked.isEmpty || item != nil else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await Self.open(item, picked: picked, store: store, then: then, here: here, close: { dismiss() })
            } catch {
                problem = error.localizedDescription
            }
        }
    }
    /// "Open Design studio" for a link to a listed conversation, else "Open link".
    static func linkTitle(_ url: URL, in conversations: [Conversation]) -> String {
        let ids = ChatLink(url)?.conversations ?? []
        return conversations.first { ids.contains($0.id) }.map { "Open \($0.name)" } ?? "Open link"
    }
    /// Opens the pick and closes the palette. A listed conversation closes it at once: its timeline shows straight away,
    /// and its newest page, read mark and watch load behind. A new DM or a join closes it once the server has made it.
    /// With `here` (a new tab's palette), the conversation opens there instead, and the palette, being the tab's
    /// content, stays until the conversation replaces it.
    static func open(
        _ item: PaletteResults.Item?, picked: [Person], store: ChatStore, then: ((ConversationID) -> Void)?,
        here: ((ConversationID) -> Void)? = nil, close: () -> Void
    ) async throws {
        switch item {
        case .person(let person)?: try await store.message(picked + [person])
        case _ where !picked.isEmpty: try await store.message(picked)
        case .conversation(let room)? where here != nil:
            here?(room.id)
            return
        case .conversation(let room)?:
            then?(room.id)
            close()
            await store.select(room.id)
            return
        case .space(let space)?: try await store.join(space)
        case .link(let url)?:
            close()
            await store.open(url: url)
            return
        case nil: return
        }
        if let here, let id = store.navigation.selectedID {
            here(id)
            return
        }  // a new DM or a joined space, in the tab
        if let then, let id = store.navigation.selectedID { then(id) }
        close()
    }
}

/// What the tab bar's + opens beside a conversation's tab: the ⌘K palette, as Safari's new tab shows its start page.
/// The pick becomes this tab's conversation; Esc closes the tab.
struct NewTab: View {
    let open: (ConversationID) -> Void
    var body: some View {
        ConversationPalette(here: open)
            .frame(maxWidth: 640, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .navigationTitle("New Tab")
    }
}
