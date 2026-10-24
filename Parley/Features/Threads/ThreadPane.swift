import ParleyDomain
import SwiftUI

/// Follow or unfollow a thread, as Google Chat's thread header offers it: a filled bell while followed.
struct ThreadFollowButton: View {
    let store: ChatStore  // passed in, not read from the environment: tests call `label` and `toggle()` outside a view
    let thread: ThreadID
    /// What a click does.
    var label: String { store.isFollowing(thread) ? "Unfollow thread" : "Follow thread" }
    func toggle() async { await store.setFollowing(!store.isFollowing(thread), for: thread) }
    var body: some View {
        let following = store.isFollowing(thread)
        Button {
            Task { await toggle() }
        } label: {
            Image(systemName: following ? "bell.fill" : "bell").contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(following ? "Unfollow thread: its replies stop notifying you" : "Follow thread: its replies notify you")
        .accessibilityLabel(label)
    }
}

/// The thread pane: the thread's first message over its replies and composer, beside a conversation or Home.
struct ThreadPane: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.paneWindow) private var paneWindow  // which window's side pane this view acts on
    let room: Conversation
    let thread: ThreadID
    var detached = false  // in its own window, which has its own close button
    var session: String?  // an Ask Gemini session: the question is the title, with no first message over the replies
    @Environment(\.openWindow) private var openWindow
    @State private var parentExpanded = false  // the first message beyond its first four lines
    @State private var emojiLoads = 0  // custom emoji pictures arrived: the header redraws
    /// The pane's thread in a window of its own; the pane closes.
    private func detach() { if let ref = store.detachThread(in: room.id) { openWindow(value: ref) } }
    var body: some View {
        VStack(spacing: 0) {
            // An Ask Gemini session is a page of its own: its toolbar has the back button, so no pane header.
            if !detached, session == nil {
                PaneHeader(
                    "Thread", close: { store.navigation.setPane(paneWindow) { $0.closeThread() } },
                    accessories: {
                        ThreadFollowButton(store: store, thread: thread)
                        Button(action: detach) { Image(systemName: "macwindow.badge.plus") }
                            .buttonStyle(.borderless).help("Open in new window").accessibilityLabel(
                                "Open in New Window")
                    })
                Divider()
            }
            if session == nil, let parent = store.history.messages.first(where: { $0.id == thread.head }) {
                // A long first message would push the replies out of the pane: four lines, a click shows the rest.
                // A message with no text shows its picture and what it carried ("Photo", the file's name…), as quotes do.
                HStack(alignment: .top, spacing: 8) {
                    if let media = parent.attachments.first(where: { $0.kind == .image || $0.kind == .video }) {
                        Thumbnail(attachment: media, load: { try await store.attachmentData($0, thumbnail: $1) }).frame(
                            width: 40, height: 40)
                    }
                    VStack(alignment: .leading) {
                        Text(parent.sender.name).font(.caption).foregroundStyle(.secondary)
                        // The timeline's own text: formatting, mentions, links and custom emoji as in the bubble.
                        NativeMessageText(
                            text: parent.text.isEmpty
                                ? QuotedMessage.summary(text: "", attachments: parent.attachments) : parent.text,
                            formatting: parent.text.isEmpty ? [] : parent.formatting, own: false,
                            lines: parentExpanded ? 0 : 4,
                            maxWidth: .infinity, redraw: emojiLoads
                        )
                        .task(id: parent.id) { await loadEmoji(in: parent) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .contentShape(Rectangle()).onTapGesture { parentExpanded.toggle() }
                .help(parentExpanded ? "Show less" : "Show the whole message")
                .onChange(of: thread) { parentExpanded = false }
                Divider()
            }
            TimelineView(conversation: room, thread: thread, detached: detached, withHead: session != nil).id(thread)
        }
        // ⌘O while the pane has the keyboard pops the thread out, as its button does.
        .focusedValue(
            \.openFocusedInWindow, detached ? nil : FocusedOpen(title: "Open Thread in New Window", open: detach))
    }
    /// Its custom emoji's pictures, which the text draws from `ImageCache` once they are there.
    private func loadEmoji(in message: Message) async {
        for range in message.formatting {
            guard case .customEmoji(let emoji) = range.style, !emoji.deleted, let picture = emoji.image,
                ImageCache.cached(picture) == nil
            else { continue }
            if (try? await ImageCache.load(picture, store.attachmentData)) != nil { emojiLoads += 1 }
        }
    }
}
