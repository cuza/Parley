import ParleyDomain
import SwiftUI

/// One timeline row with its grouping decided from a single snapshot, so rows never index a list that changed meanwhile.
struct TimelineRow: Identifiable, Hashable {
    let message: Message
    let begins: Bool  // first of a run: same sender, gaps under 5 min
    let ends: Bool  // last of a run
    let newDay: Bool
    var seenBy: [String] = []  // names of readers whose receipt ends at this message
    var draft = false  // a thread's first message whose reply box holds a draft
    var transcriptOpen = false  // its voice message's whole transcript shows, not one line; its card's cut paragraph, all of it; or its original, not Google's translation
    var id: MessageID { message.id }

    static func rows(
        _ items: [Message], seen: [MessageID: [String]] = [:], drafts: Set<ThreadID> = [],
        transcripts: Set<MessageID> = []
    ) -> [TimelineRow] {
        items.indices.map { index in
            var message = items[index]
            // A translated message shows its translation until opened ("View original"), which shows the original.
            if let translation = message.translation, !transcripts.contains(message.id) {
                message.text = translation.text
                message.formatting = translation.formatting
            }
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            return TimelineRow(
                message: message,
                begins: previous.map {
                    $0.isSystem || $0.sender.id != message.sender.id
                        || message.createdAt.timeIntervalSince($0.createdAt) >= 300
                } ?? true,
                ends: next.map {
                    $0.isSystem || $0.sender.id != message.sender.id
                        || $0.createdAt.timeIntervalSince(message.createdAt) >= 300
                } ?? true,
                newDay: previous.map { !Calendar.current.isDate($0.createdAt, inSameDayAs: message.createdAt) } ?? true,
                seenBy: seen[message.id] ?? [], draft: drafts.contains(ThreadID(head: message.id)),
                transcriptOpen: transcripts.contains(message.id))
        }
    }
}

/// A conversation's or thread's messages, with the floating composer under them.
struct TimelineView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.paneWindow) private var paneWindow  // which window's side pane this view acts on
    let conversation: Conversation
    var thread: ThreadID?
    var detached = false  // a thread in its own window
    var withHead = false  // the thread's first message leads its replies (an Ask Gemini session, as on the web)
    @State private var atBottom = true
    @State private var arrivedAway = 0  // new messages while scrolled up: the scroll-to-bottom badge
    @State private var reporting: Message?
    @State private var deleting: Message?  // asks before deleting a message for everyone
    @State private var scrollRequest = 0
    @AppStorage("timelineStyle") private var style = TimelineStyle.bubbles
    @AppStorage(Wallpaper.key(dark: false)) private var wallpaper = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var darkWallpaper = Wallpaper.none
    @AppStorage(BubblePalette.colorKey(dark: false)) private var bubbleColor = ""
    @AppStorage(BubblePalette.colorKey(dark: true)) private var darkBubbleColor = ""
    @AppStorage(Wallpaper.doodlesKey) private var doodles = true
    @State private var composerHeight: CGFloat = 0  // the floating composer's height: the timeline's bottom inset
    /// A blocked person's messages stay hidden, as Google Chat hides them.
    private var items: [Message] {
        var all = store.timeline(conversation.id, thread: thread)
        if withHead, let thread, var head = store.history.messages.first(where: { $0.id == thread.head }) {
            head.replyCount = 0  // inside its own thread, no "1 reply" link
            all.insert(head, at: 0)
        }
        let blocked = store.rooms.blockedPeople
        return blocked.isEmpty ? all : all.map { blocked.contains($0.sender.id) ? ChatStore.blockedView($0) : $0 }
    }
    private var actions: MessageRowActions {
        MessageRowActions(
            react: { emoji, message in Task { await store.react(emoji, to: message) } },
            toggleTranscript: { store.history.toggleTranscript($0.id) },
            dismissCard: { store.dismissCard(of: $0) },
            clickCard: { message, card, action, inputs in
                await store.clickCard(message, card: card, action: action, inputs: inputs)
            },
            reactCustom: { emoji, message in Task { await store.react(emoji.text, custom: emoji, to: message) } },
            customEmoji: store.allowsCustomEmoji(in: conversation.id) ? { store.customEmojiNow() } : nil,
            reactors: { reaction, message in await store.reactorsLine(reaction, on: message.id) },
            openThread: { message in Task { await store.openThread(message, window: paneWindow) } },
            quote: { store.quote($0) },
            forward: { store.forwarding = $0 },
            // A forward's message lives in the conversation it came from: open it there.
            showQuoted: { id in
                Task {
                    if !id.rawValue.hasPrefix(conversation.id.rawValue + "/"), let url = ChatLink.url(message: id),
                        let link = ChatLink(url)
                    {
                        _ = await store.open(link)
                    } else {
                        await store.showQuoted(id, in: conversation.id, window: paneWindow)
                    }
                }
            },
            message: { person in Task { do { try await store.message([person]) } catch { store.report(error) } } },
            person: { store.person($0, in: conversation.id) },
            cardDetails: { await store.cardDetails(of: $0) },
            showDetails: { store.showDetails($0, window: paneWindow) },
            openChatLink: { link, _ in await store.open(link) },
            retry: { message in Task { await store.retry(message) } },
            edit: { store.edit($0) },
            delete: { deleting = $0 },
            star: { starred, message in Task { await store.setStarred(starred, message) } },
            pin: { pinned, message in Task { await store.setBoardPinned(pinned, message) } },
            markUnread: { message in Task { await store.markUnread(from: message) } },
            report: store.rooms.permissions[conversation.id]?.reportMessages == true ? { reporting = $0 } : nil,
            readers: { [conversation] message in
                conversation.kind == .space
                    ? [] : store.readers(of: message).map { store.name(of: $0, in: conversation.id) }
            },
            loadAttachment: { attachment, thumbnail in try await store.attachmentData(attachment, thumbnail: thumbnail)
            },
            emojiUsage: EmojiUsage())
    }
    /// The main timeline shows a window opened at an old message, away from the newest ones.
    private var isWindow: Bool { thread == nil && store.history.detached.contains(conversation.id) }
    /// Receipts show in the conversation's own timeline, not in a thread.
    private func rows(_ items: [Message]) -> [TimelineRow] {
        let seen =
            thread == nil
            ? store.seen(in: conversation).mapValues { $0.map { store.name(of: $0, in: conversation.id) } } : [:]
        return TimelineRow.rows(
            items, seen: seen, drafts: thread == nil ? store.threadsWithDrafts(in: conversation.id) : [],
            transcripts: store.history.openTranscripts)
    }
    var body: some View {
        let items = items  // filtered and sorted once per update, not once per use
        // The composer floats over the timeline, which scrolls under it with a bottom inset of the composer's height.
        Group {
            if items.isEmpty, store.history.loading.contains(store.key(conversation.id, thread)) {  // not empty: not loaded yet
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, composerHeight)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Start the conversation", systemImage: "bubble.left", description: Text("Send a message below.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, composerHeight)  // full width: the composer spans it
            } else {
                MessageTable(
                    rows: rows(items), meID: store.me.id, kind: conversation.kind, style: style,
                    look: [wallpaper.rawValue, darkWallpaper.rawValue, bubbleColor, darkBubbleColor].joined(
                        separator: "/"),
                    highlighted: store.history.highlightedID,
                    identifier: thread == nil ? "timeline" : "thread", actions: actions,
                    nearTop: { Task { await store.loadOlderIfNeeded(conversation.id, thread: thread) } },
                    nearBottom: { Task { await store.loadNewerIfNeeded(conversation.id) } }, detached: isWindow,
                    atBottomChanged: {
                        atBottom = $0
                        if $0 { arrivedAway = 0 }
                    }, scrollRequest: scrollRequest,
                    bottomInset: composerHeight)
            }
        }
        .background { WallpaperView(doodles: doodles) }
        .sheet(item: $reporting) { ReportSheet(message: $0) }
        .confirmationDialog("Delete this message?", isPresented: Binding(isPresent: $deleting)) {
            Button("Delete", role: .destructive) {
                if let message = deleting { Task { await store.deleteMessage(message) } }
            }
        } message: {
            Text("It's deleted for everyone.")
        }
        .overlay(alignment: .top) {
            if store.history.loading.contains(store.key(conversation.id, thread)) && !items.isEmpty {
                ProgressView().controlSize(.small).padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if (!atBottom || isWindow) && !items.isEmpty {
                // From a window opened at an old message, the newest messages are a reload away, not a scroll.
                Button {
                    if isWindow {
                        Task {
                            await store.returnToNewest(conversation.id)
                            scrollRequest += 1
                        }
                    } else {
                        scrollRequest += 1
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)).frame(
                        width: 38, height: 38
                    )
                    .floatingGlass(Circle(), interactive: true)
                    .overlay(alignment: .top) {
                        if arrivedAway > 0 {
                            Text("\(arrivedAway)").font(.caption2.bold()).foregroundStyle(.white).padding(
                                .horizontal, 5
                            ).padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule()).offset(y: -8)
                        }
                    }
                }.buttonStyle(.plain).padding(16).padding(.bottom, composerHeight)
                    .help("Scroll to the newest message").accessibilityLabel("Scroll to the newest message")
            }
        }
        .overlay(alignment: .bottom) {
            // Its own view, so typing and the composer's own state update only the composer, not the timeline.
            ComposerBar(conversation: conversation, thread: thread, detached: detached)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    composerHeight = $0
                }
        }
        .onChange(of: items.last?.id) { _, _ in if !atBottom { arrivedAway += 1 } }
        .dropDestination(for: DroppedFile.self) { dropped, _ in  // files dropped anywhere on the conversation join the draft
            let files = dropped.map(\.url).filter(\.isFileURL)
            store.attach(files, conversation: conversation.id, thread: thread)
            return !files.isEmpty
        }
    }
}

/// A file dropped on the conversation: one from Finder, used where it is, or a promised one (Photos, a screenshot's
/// thumbnail, the timeline's own attachments), received into a temporary copy as the composer receives it.
struct DroppedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in DroppedFile(url: url) })
        FileRepresentation(importedContentType: .item) { received in
            // SwiftUI deletes the received file once this returns: keep a copy.
            let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return DroppedFile(url: copy)
        }
    }
}
