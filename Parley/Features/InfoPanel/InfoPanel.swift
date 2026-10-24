import AppKit
import ParleyDomain
import Quartz
import SwiftUI

/// The conversation's info, in the inspector (⇧⌘I or the title), as Messages and Telegram show it: who or what it is,
/// mute, pin and search, the members of a space or group, and the media, files and links its loaded messages share.
struct InfoPanel: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.paneWindow) private var paneWindow  // which window's side pane this view acts on
    let room: Conversation
    let search: (() -> Void)?  // nil in a conversation's own window: search opens results in the main window
    @State private var tab = SharedCategory.media
    @State private var card: PersonID?
    @State private var files = AttachmentFiles { _, _ in throw CancellationError() }
    @State private var renaming = false
    @State private var newName = ""
    @State private var pickingEmoji = false
    @State private var addingPeople = false
    @State private var editingDetails = false
    @State private var deleting = false
    @State private var allMembers = false
    @State private var memberFilter = ""
    /// Members listed in the panel itself. A Form builds every row up front (about 3 ms each with avatar, presence, menu
    /// and card), so a large space shows the first ones and the rest in a lazy, searchable list.
    static let inlineMembers = 20

    private var roster: [Person] { store.roster(room) }
    private var partner: Person? { room.kind == .direct ? roster.first { $0.id != store.me.id } : nil }
    private var allowed: ConversationPermissions { store.rooms.permissions[room.id] ?? .init() }

    var body: some View {
        // A header as the thread pane has, with its close button. It also keeps the Form below the toolbar: a scroll view
        // reaching under it takes over the toolbar's frosted backdrop and leaves it clear across the window.
        VStack(spacing: 0) {
            PaneHeader("Info", close: { store.navigation.setPane(paneWindow) { $0.closeInfo() } })
            Divider()
            form
        }
    }

    private var form: some View {
        Form {
            Section { header }
            Section {
                actions
                NotificationLevelPicker(room: room)
                history
            }
            if room.kind == .space, room.guidelines != nil || allowed.editDetails {
                Section("Guidelines") { guidelines }
            }
            if let board = store.rooms.pinned[room.id], !board.isEmpty {
                Section("Board") { ForEach(board) { pinned($0) } }
            }
            if room.kind != .direct {
                Section("\(roster.count) members") {
                    ForEach(roster.prefix(Self.inlineMembers)) { member($0) }
                    if roster.count > Self.inlineMembers {
                        Button("Show All \(roster.count) Members…") { allMembers = true }
                    }
                }
            }
            if room.kind == .space, allowed.deleteSpace {
                Section { Button("Delete Space…", role: .destructive) { deleting = true } }
            }
            SharedContentSection(room: room, tab: $tab, files: files)
        }
        .formStyle(.grouped)
        .background(QuickLookAnchor(files: files))
        .onExitCommand { store.navigation.setPane(paneWindow) { $0.closeInfo() } }
        .alert("Rename “\(room.name)”", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await store.rename(room.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $addingPeople) { AddPeopleSheet(room: room, roster: roster) }
        .sheet(isPresented: $allMembers) { membersSheet }
        .sheet(isPresented: $editingDetails) { SpaceDetailsSheet(room: room) }
        // Google Chat's wording: deleting removes every message for all members.
        .alert("Delete “\(room.name)”?", isPresented: $deleting) {
            Button("Delete", role: .destructive) {
                store.navigation.setPane(paneWindow) { $0.closeInfo() }
                Task { await store.deleteSpace(room.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The space and all its messages and tasks are deleted for every member.")
        }
        .task(id: room.id) {
            files.load = { [store] attachment, thumbnail in
                try await store.attachmentData(attachment, thumbnail: thumbnail)
            }
            files.messages = { [store, id = room.id] in  // Quick Look's ←/→ order: oldest first
                store.history.messages.filter { $0.conversationID == id }.sorted { $0.createdAt < $1.createdAt }
            }
            async let permissions: Void = store.loadPermissions(room.id)
            async let board: Void = store.loadPinned(room.id)
            await store.loadMembers(room.id)
            await permissions
            await board
        }
        .task(id: "\(room.id)/\(tab.rawValue)") { await store.loadShared(tab, in: room.id) }
    }

    // MARK: Header
    private var header: some View {
        VStack(spacing: 6) {
            if room.kind == .space, allowed.editProfile {
                Button {
                    pickingEmoji = true
                } label: {
                    avatar
                }.buttonStyle(.plain).help("Choose an emoji")
                    .emojiPickerPopover(isPresented: $pickingEmoji) { emoji in
                        Task { await store.setEmoji(emoji, room.id) }
                    }
            } else {
                avatar
            }
            Text(room.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            if room.external == true { ExternalBadge() }
            if let partner {
                if let email = partner.email { Text(email).foregroundStyle(.secondary).textSelection(.enabled) }
                if let presence = store.presence.availability[partner.id], presence != .offline {
                    HStack(spacing: 5) {
                        PresenceDot(presence: presence)
                        Text(presence.title)
                    }.font(.callout).foregroundStyle(.secondary)
                }
                if let status = store.presence.customStatus[partner.id] {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                if let description = room.description {
                    Text(description).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
                }
                Text("\(roster.count) members").font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 6)
    }
    private var avatar: some View {
        Avatar(room: room, size: 72, url: partner?.avatarURL)
    }

    // MARK: Actions
    private var actions: some View {
        HStack {
            Self.action(room.muted ? "Unmute" : "Mute", icon: room.muted ? "bell" : "bell.slash") {
                Task { await store.setMuted(!room.muted, room.id) }
            }
            Self.action(room.pinned ? "Unpin" : "Pin", icon: room.pinned ? "pin.slash" : "pin") {
                Task { await store.setSidebarPinned(!room.pinned, room.id) }
            }
            if let search {
                Self.action("Search", icon: "magnifyingglass", help: "Search this conversation (⌘F)", search)
            }
            Self.action("Copy link", icon: "link", help: "Copy a link to this conversation") {
                ChatLink.copy(ChatLink.url(room.id))
            }
            if allowed.editProfile {
                Self.action("Rename", icon: "pencil") {
                    newName = room.name
                    renaming = true
                }
            }
            if allowed.manageMembers { Self.action("Add people", icon: "person.badge.plus") { addingPeople = true } }
            if let partner {
                Self.action("Details", icon: "person.text.rectangle", help: "Show \(partner.name)’s details") {
                    store.showDetails(partner, window: paneWindow)
                }
            }
        }
    }
    /// One of the panel's action buttons: an icon over its name. A person's details pane uses them too.
    static func action(_ title: String, icon: String, help: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17)).frame(height: 22)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.borderless).help(help ?? title)
    }

    /// History on keeps messages; off has Google delete new ones after 24 hours, as Google Chat's menu describes it.
    @ViewBuilder private var history: some View {
        if room.kind != .direct, let off = room.historyOff {
            Toggle(isOn: Binding(get: { !off }, set: { on in Task { await store.setHistory(on, for: room.id) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History")
                    Text(off ? "New messages are deleted after 24 hours" : "Messages are kept").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }.disabled(!allowed.toggleHistory)
        }
    }
    @ViewBuilder private var guidelines: some View {
        if let guidelines = room.guidelines {
            Text(guidelines).textSelection(.enabled)
        } else {
            Text("No guidelines").foregroundStyle(.secondary)
        }
        if allowed.editDetails { Button("Edit Description and Guidelines…") { editingDetails = true } }
    }

    // MARK: Members
    /// Every member, in a List, which builds only the rows on screen; the field filters by name or email.
    private var membersSheet: some View {
        let shown =
            memberFilter.isEmpty
            ? roster
            : roster.filter {
                $0.name.localizedCaseInsensitiveContains(memberFilter)
                    || ($0.email?.localizedCaseInsensitiveContains(memberFilter) ?? false)
            }
        return VStack(spacing: 0) {
            HStack {
                Text("\(roster.count) members").font(.headline)
                Spacer()
                Button("Done") { allMembers = false }.keyboardShortcut(.defaultAction)
            }.padding(12)
            TextField("Search members", text: $memberFilter).textFieldStyle(.roundedBorder).padding(.horizontal, 12)
                .padding(.bottom, 8)
            List(shown) { member($0) }
        }
        .frame(width: 360, height: 520)
    }
    private func member(_ person: Person) -> some View {
        let isMe = person.id == store.me.id
        let role = store.rooms.roles[room.id]?[person.id]
        return Button {
            card = person.id
        } label: {
            PersonRow(
                person.name, caption: person.email, avatarURL: person.avatarURL,
                presence: store.presence.availability[person.id],
                isMe: isMe, external: store.isExternal(person)
            ) {
                if room.kind == .space, let role, role != .member {
                    Text(role == .owner ? "Owner" : "Manager").font(.caption).foregroundStyle(.secondary)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(isMe)
        .contextMenu {
            // Google Chat's wording; an owner's role isn't changed here.
            if room.kind == .space, !isMe, role != .owner {
                if role == .manager {
                    if allowed.changeManagers {
                        Button("Change to Member") {
                            Task { await store.setRole(.member, for: person.id, in: room.id) }
                        }
                    }
                } else if allowed.changeRoles {
                    Button("Change to Manager") { Task { await store.setRole(.manager, for: person.id, in: room.id) } }
                }
            }
            if allowed.manageMembers, !isMe {
                Button("Remove from \(room.kind == .space ? "space" : "group")", role: .destructive) {
                    Task { await store.removeMember(person.id, from: room.id) }
                }
            }
        }
        .popover(isPresented: Binding(get: { card == person.id }, set: { if !$0 { card = nil } }), arrowEdge: .leading)
        {
            VStack(alignment: .leading, spacing: 8) {
                PersonCard(person: person, details: { await store.cardDetails(of: person) })
                HStack {
                    Button("Show Details") {
                        card = nil
                        store.showDetails(person, window: paneWindow)
                    }
                    Button("Message \(person.name)") {
                        card = nil
                        Task { do { try await store.message([person]) } catch { store.report(error) } }
                    }
                }.padding([.horizontal, .bottom], 14)
            }.padding(.top, 8)
        }
    }

    // MARK: Pinned
    /// A message on the board: who sent it and what it says; a click shows it in the conversation.
    private func pinned(_ message: Message) -> some View {
        Button {
            Task { await store.jump(message) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "\(message.sender.id == store.me.id ? "You" : store.name(of: message.sender.id, in: room.id)) · \(message.createdAt.formatted(date: .abbreviated, time: .omitted))"
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(
                    QuotedMessage.summary(
                        text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments)
                )
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Show in Chat")
        .contextMenu { Button("Unpin from Board") { Task { await store.setBoardPinned(false, message) } } }
    }
}

/// Quick Look finds its controller in the responder chain; `AttachmentFiles.preview` makes this view first responder.
private struct QuickLookAnchor: NSViewRepresentable {
    let files: AttachmentFiles
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.files = files
        files.responder = view
    }
    final class AnchorView: NSView {
        weak var files: AttachmentFiles?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
            MainActor.assumeIsolated { files?.previewItems.isEmpty == false }
        }
        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { files?.beginControl(panel) }
        }
        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { files?.endControl(panel) }
        }
    }
}
