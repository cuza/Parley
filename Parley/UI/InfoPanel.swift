import AppKit
import Quartz
import SwiftUI

/// When the conversation notifies me, in web Chat's words; a pick is shown at once and sent (put back if refused).
/// In a menu it is a submenu.
struct NotificationLevelPicker: View {
    let store: ChatStore
    let room: Conversation
    var body: some View {
        Picker("Notifications", selection: Binding(get: { room.notificationLevel }, set: { level in
            if let level, level != room.notificationLevel { Task { await store.setNotificationLevel(level, room.id) } }
        })) {
            ForEach(NotificationLevel.choices(for: room.kind, current: room.notificationLevel), id: \.self) { Text($0.title).tag(Optional($0)) }
        }
    }
}

/// The conversation's info, in the inspector (⌘I or the title), as Messages and Telegram show it: who or what it is,
/// mute, pin and search, the members of a space or group, and the media, files and links its loaded messages share.
struct InfoPanel: View {
    @Bindable var store: ChatStore
    let room: Conversation
    let search: (() -> Void)?   // nil in a conversation's own window: search opens results in the main window
    @State private var tab = SharedCategory.media
    @State private var card: PersonID?
    @State private var files = AttachmentFiles { _, _ in throw CancellationError() }
    @State private var renaming = false
    @State private var newName = ""
    @State private var pickingEmoji = false
    @State private var addingPeople = false

    private var roster: [Person] { store.roster(room) }
    private var partner: Person? { room.kind == .direct ? roster.first { $0.id != store.me.id } : nil }
    private var allowed: ConversationPermissions { store.permissions[room.id] ?? .init() }

    var body: some View {
        // The Divider keeps the Form below the toolbar: a scroll view reaching under it takes over the toolbar's frosted
        // backdrop and leaves it clear across the window.
        VStack(spacing: 0) { Divider(); form }
    }

    private var form: some View {
        Form {
            Section { header }
            Section { actions; NotificationLevelPicker(store: store, room: room) }
            if room.kind != .direct { Section("\(roster.count) members") { ForEach(roster) { member($0) } } }
            Section { shared } header: {
                Picker("Shared", selection: $tab) { ForEach(SharedCategory.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
            } footer: { footer }
        }
        .formStyle(.grouped)
        .background(QuickLookAnchor(files: files))
        .onExitCommand { store.info = false }
        .alert("Rename “\(room.name)”", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await store.rename(room.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $addingPeople) { AddPeopleSheet(store: store, room: room, roster: roster) }
        .task(id: room.id) {
            files.load = { [store] attachment, thumbnail in try await store.attachmentData(attachment, thumbnail: thumbnail) }
            files.messages = { [store, id = room.id] in   // Quick Look's ←/→ order: oldest first
                store.messages.filter { $0.conversationID == id }.sorted { $0.createdAt < $1.createdAt }
            }
            async let permissions: Void = store.loadPermissions(room.id)
            await store.loadMembers(room.id)
            await permissions
        }
        .task(id: "\(room.id)/\(tab.rawValue)") { await store.loadShared(tab, in: room.id) }
    }

    // MARK: Header
    private var header: some View {
        VStack(spacing: 6) {
            if room.kind == .space, allowed.editProfile {
                Button { pickingEmoji = true } label: { avatar }.buttonStyle(.plain).help("Choose an emoji")
                    .popover(isPresented: $pickingEmoji) {
                        EmojiPicker(frequent: EmojiUsage().top(EmojiPicker.columns), pick: { emoji in
                            pickingEmoji = false
                            Task { await store.setEmoji(emoji, room.id) }
                        }, close: { pickingEmoji = false })
                    }
            } else { avatar }
            Text(room.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            if let partner {
                if let email = partner.email { Text(email).foregroundStyle(.secondary).textSelection(.enabled) }
                if let presence = store.presence[partner.id], let text = Self.text(presence) {
                    HStack(spacing: 5) { PresenceDot(presence: presence); Text(text) }.font(.callout).foregroundStyle(.secondary)
                }
                if let status = store.statuses[partner.id] { Text(status).font(.callout).foregroundStyle(.secondary) }
            } else {
                if let description = room.description {
                    Text(description).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
                }
                Text("\(roster.count) members").font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 6)
    }
    private var avatar: some View {
        Avatar(name: room.name, space: room.kind == .space, size: 72, url: partner?.avatarURL ?? room.avatarURL, emoji: room.emoji)
    }
    static func text(_ presence: Presence) -> String? {
        switch presence {
        case .available: "Active"
        case .away: "Away"
        case .doNotDisturb: "Do not disturb"
        case .offline: nil
        }
    }

    // MARK: Actions
    private var actions: some View {
        HStack {
            action(room.muted ? "Unmute" : "Mute", icon: room.muted ? "bell" : "bell.slash") { Task { await store.setMuted(!room.muted, room.id) } }
            action(room.pinned ? "Unpin" : "Pin", icon: room.pinned ? "pin.slash" : "pin") { Task { await store.setPinned(!room.pinned, room.id) } }
            if let search { action("Search", icon: "magnifyingglass", help: "Search messages (⇧⌘F)", search) }
            if allowed.editProfile { action("Rename", icon: "pencil") { newName = room.name; renaming = true } }
            if allowed.manageMembers { action("Add people", icon: "person.badge.plus") { addingPeople = true } }
        }
    }
    private func action(_ title: String, icon: String, help: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 17)).frame(height: 22); Text(title).font(.caption) }
                .frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.borderless).help(help ?? title)
    }

    // MARK: Members
    private func member(_ person: Person) -> some View {
        let isMe = person.id == store.me.id
        return Button { card = person.id } label: {
            HStack(spacing: 10) {
                Avatar(name: person.name, size: 28, url: person.avatarURL)
                    .overlay(alignment: .bottomTrailing) { PresenceDot(presence: store.presence[person.id], size: 8).offset(x: 2, y: 2) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(isMe ? "\(person.name) (you)" : person.name).lineLimit(1)
                    if let email = person.email { Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(isMe)
        .contextMenu {
            if allowed.manageMembers, !isMe {
                Button("Remove from \(room.kind == .space ? "space" : "group")", role: .destructive) {
                    Task { await store.removeMember(person.id, from: room.id) }
                }
            }
        }
        .popover(isPresented: Binding(get: { card == person.id }, set: { if !$0 { card = nil } }), arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                PersonCard(person: person)
                Button("Message \(person.name)") {
                    card = nil
                    Task { do { try await store.message([person]) } catch { store.report(error) } }
                }.padding([.horizontal, .bottom], 14)
            }.padding(.top, 8)
        }
    }

    // MARK: Shared content
    @ViewBuilder private var shared: some View {
        let items = self.items
        if items.isEmpty {
            Text("No \(tab.rawValue.lowercased())").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if tab == .media {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 4)], spacing: 4) {
                ForEach(items) { item in
                    Thumbnail(attachment: item.attachment, load: files.load)
                        .onTapGesture { files.preview(item.attachment) }
                        .contextMenu { showInChat(item) }
                        .help("\(item.attachment.name) · \(item.sender), \(item.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        } else {
            ForEach(items) { item in
                Button { item.attachment.kind == .link ? open(item.attachment) : files.preview(item.attachment) } label: { row(item) }.buttonStyle(.plain)
                    .contextMenu { showInChat(item) }
            }
        }
    }
    /// Right-click on a shared item: go to the message that shared it.
    @ViewBuilder private func showInChat(_ item: SharedContent.Item) -> some View {
        if item.messageID != nil { Button("Show in Chat") { Task { await store.showShared(item, in: room.id) } } }
    }
    private func open(_ link: Attachment) { if let url = link.url { NSWorkspace.shared.open(url) } }
    private func row(_ item: SharedContent.Item) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.attachment.kind == .link ? NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
                  : NSWorkspace.shared.icon(for: item.attachment.utType ?? .data))
                .resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.attachment.name).lineLimit(1).truncationMode(.middle)
                Text("\(item.attachment.kind == .link ? item.attachment.url?.host() ?? "" : item.attachment.detail) · \(item.sender), \(item.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle()).help(item.attachment.url?.absoluteString ?? item.attachment.name)
    }
    /// The server's list of what the conversation shares; until it arrives (or if it fails), what loaded messages share.
    private var fromServer: [SharedContent.Item]? { store.shared[store.sharedKey(room.id, tab)] }
    private var items: [SharedContent.Item] {
        if let fromServer { return fromServer }
        let content = SharedContent(store.messages.filter { $0.conversationID == room.id })
        return switch tab { case .media: content.media; case .files: content.files; case .links: content.links }
    }
    @ViewBuilder private var footer: some View {
        if fromServer != nil {
            if store.sharedMore.contains(store.sharedKey(room.id, tab)) {
                HStack {
                    Spacer()
                    Button("Load more") { Task { await store.loadShared(tab, in: room.id, more: true) } }.buttonStyle(.link)
                }.font(.caption)
            }
        } else {
            HStack {
                Text("From loaded messages")
                Spacer()
                if store.loading.contains(store.key(room.id, nil)) { ProgressView().controlSize(.small) }
                else if store.hasMore.contains(store.key(room.id, nil)) {
                    Button("Load older") { Task { await store.loadOlderIfNeeded(room.id) } }.buttonStyle(.link)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// People to add to a space or group: search by name or email, tick several, add them together.
struct AddPeopleSheet: View {
    let store: ChatStore
    let room: Conversation
    let roster: [Person]
    @State private var query = ""
    @State private var found: [Person] = []
    @State private var picked: [Person] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add people to “\(room.name)”").font(.headline)
            TextField("Name or email", text: $query).textFieldStyle(.roundedBorder)
            List(found.filter { person in !roster.contains { $0.id == person.id } }) { person in
                Toggle(isOn: Binding(get: { picked.contains(person) }, set: { on in
                    if on { picked.append(person) } else { picked.removeAll { $0 == person } }
                })) {
                    HStack(spacing: 8) {
                        Avatar(name: person.name, size: 22, url: person.avatarURL)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.name).lineLimit(1)
                            if let email = person.email, email != person.name { Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }.toggleStyle(.checkbox)
            }.frame(height: 260)
            HStack {
                Text(picked.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    dismiss()
                    Task { await store.addMembers(picked, to: room.id) }
                }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }.padding(18).frame(width: 420)
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))   // one search per pause in typing
                guard !Task.isCancelled else { return }
                found = (try? await store.searchPeople(query)) ?? []
            }
    }
}

/// A square media thumbnail; a play badge on videos.
struct Thumbnail: View {
    let attachment: Attachment
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    @State private var image: NSImage?
    var body: some View {
        Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .overlay { if attachment.kind == .video { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white, .black.opacity(0.4)) } }
            .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
            .task(id: attachment) { image = try? await ImageCache.load(attachment, load) }
            .accessibilityLabel(attachment.name).accessibilityAddTraits(.isButton)
    }
}

/// Quick Look finds its controller in the responder chain; `AttachmentFiles.preview` makes this view first responder.
private struct QuickLookAnchor: NSViewRepresentable {
    let files: AttachmentFiles
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.files = files; files.responder = view }
    final class AnchorView: NSView {
        weak var files: AttachmentFiles?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { MainActor.assumeIsolated { files?.previewItems.isEmpty == false } }
        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { files?.beginControl(panel) } }
        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { files?.endControl(panel) } }
    }
}
