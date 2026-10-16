import SwiftUI

/// Ask Gemini as web Chat shows it: a greeting and the recent sessions, each one a thread of the Ask Gemini DM. Asking
/// from the home's composer starts a new session and opens it; a session opens full width, and closing it comes back.
struct GeminiPane: View {
    @Bindable var store: ChatStore
    let room: Conversation
    /// When this pane appeared: a session of mine started after it is the question just asked, opened at once.
    @State private var since = Date.now
    var body: some View {
        Group {
            if let thread = store.threadID {
                ThreadPane(store: store, room: room, thread: thread,
                           session: store.messages.first { $0.id == thread }.map(ThreadsPane.preview) ?? "Ask Gemini")
                    .background {
                        // Esc goes back to the home wherever focus is, even right after opening with none. While the
                        // composer quotes or edits, Esc is the composer's, to drop the quote or end the edit first.
                        let scope = store.key(room.id, thread)
                        if store.quoting[scope] == nil, store.editing[scope] == nil {
                            Button("") { store.threadID = nil }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
                        }
                    }
            } else {
                home
            }
        }
        .task(id: store.threadID == nil) { if store.threadID == nil { await store.loadThreads(room.id) } }
        .onAppear { since = .now }
        .onChange(of: latestQuestion) { _, latest in
            guard store.threadID == nil, let question = store.messages.first(where: { $0.id == latest }), question.createdAt > since else { return }
            Task { await store.openThread(question) }
        }
        .toolbar(removing: .title)   // "Ask Gemini" is the title; the window keeps "Parley" for its menus
        .toolbar {
            if store.threadID != nil {   // a session is a page of its own: back to the home, as Esc and ⌘[ go
                ToolbarItem(placement: .navigation) {
                    Button { store.threadID = nil } label: { Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly) }
                        .help("Back to Ask Gemini")
                }
            }
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Text("Ask Gemini").font(.title3.weight(.semibold))
                    Text("Beta").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            .titleWithoutGlass()
        }
    }
    /// My newest question that Google has: a sent session's first message.
    private var latestQuestion: MessageID? {
        store.timeline(room.id).last { $0.sender.id == store.me.id && $0.threadID == nil && $0.delivery == .sent }?.id
    }
    private var home: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    Text(Self.greeting(name: store.me.name, at: .now)).font(.system(size: 34, weight: .regular))
                    Text("Ask about your chats, files, email and calendar.").foregroundStyle(.secondary)
                }
                .padding(.top, 48).padding(.bottom, 28)
                sessions.frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)   // the scroll view spans the pane, so its edge under the toolbar does too
            }
            ComposerBar(store: store, conversation: room)
            HStack(spacing: 4) {
                Text("Gemini in Workspace can make mistakes, including about people.")
                Link("Learn more", destination: Self.learnMore)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
        }
    }
    @ViewBuilder private var sessions: some View {
        if store.threadSummaries[room.id] == nil {
            ProgressView().padding(.top, 24)
        } else if store.threadSummaries[room.id]?.isEmpty == true {
            Text("No recent chats. Ask something below to start one.").foregroundStyle(.secondary).padding(.top, 24)
        } else if let all = store.threadSummaries[room.id] {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                ForEach(all) { session in
                    Button { Task { await store.openThread(session.head) } } label: { row(session) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }
    private func row(_ session: ThreadSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.alignleft").foregroundStyle(.secondary).frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(ThreadsPane.preview(session.head)).fontWeight(session.unreadCount > 0 ? .semibold : .regular).lineLimit(1)
            Spacer(minLength: 8)
            Text(session.lastReply, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            if session.unreadCount > 0 { Circle().fill(Color.accentColor).frame(width: 8, height: 8).accessibilityLabel("Unread") }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
    /// "Good evening, Dave": by the hour and my first name.
    static func greeting(name: String, at date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening"
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Good \(part)" : "Good \(part), \(first)"
    }
    static let learnMore = URL(string: "https://support.google.com/a/users/answer/16304582")!
}
