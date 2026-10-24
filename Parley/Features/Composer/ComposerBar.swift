import AppKit
import ParleyDomain
import SwiftUI

/// The floating composer under a timeline. Its own view so its state (the draft, the pickers, the typing line) updates
/// only it: inside the timeline view, every keystroke re-ran the timeline's update.
struct ComposerBar: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.paneWindow) private var paneWindow  // which window's side pane this view acts on
    let conversation: Conversation
    var thread: ThreadID?
    var detached = false  // a thread in its own window
    @State private var formatBar = false  // the composer's formatting row
    @State private var gifPicker = false
    @State private var emojiPicker = false
    @State private var composerHandle = ComposerHandle()
    @State private var linking: LinkForm.Draft?  // the link form, with the selection it started from
    @State private var recorder = VoiceRecorder()
    /// Who's typing here, or the app at work, in a thought bubble at the end of the conversation (the timeline makes room).
    @ViewBuilder private var typingBubble: some View {
        let known = { (id: PersonID) in
            store.person(id, in: conversation.id) ?? Person(id: id, name: store.name(of: id, in: conversation.id))
        }
        if let activity = store.activity(conversation.id, thread: thread) {
            TypingBubble(
                typists: [known(activity.person)], activity: activity.label,
                dots: conversation.app == .gemini
                    ? [
                        Color(red: 0.31, green: 0.49, blue: 0.95), Color(red: 0.54, green: 0.39, blue: 0.91),
                        Color(red: 0.82, green: 0.38, blue: 0.62),
                    ]
                    : [.secondary, .secondary, .secondary])
        } else if case let typists = store.typists(conversation.id, thread: thread), !typists.isEmpty {
            TypingBubble(typists: typists.map(known), showsName: conversation.kind != .direct)  // a DM's picture says who
        }
    }
    private var blockedPartner: PersonID? {
        guard thread == nil, conversation.kind == .direct, let partner = store.partner(in: conversation),
            store.rooms.blockedPeople.contains(partner)
        else { return nil }
        return partner
    }
    var body: some View {
        Group {
            if let blockedPartner { BlockedCover(person: blockedPartner, name: conversation.name) } else { composer }
        }
        .onChange(of: conversation.id) { recorder.cancel() }  // a recording belongs to the conversation it started in
        .onDisappear { recorder.cancel() }
        // Mentioning people who aren't members, Google Chat asks before adding them; Cancel goes back to the draft.
        .alert("Add to this conversation?", isPresented: Binding(isPresent: Bindable(store.drafting).addPrompts[scope]))
        {
            Button("Add and Send") {
                Task { await store.send(conversation: conversation.id, thread: thread, adding: true) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Send Without Adding") {
                Task { await store.send(conversation: conversation.id, thread: thread, adding: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "New members can see the messages sent before they joined. Add \((store.drafting.addPrompts[scope] ?? []).formatted(.list(type: .and)))?"
            )
        }
        .onAppear { composerHandle.askForLink = { linking = LinkForm.Draft(text: composerHandle.selectedText) } }
        .sheet(item: $linking) { draft in
            LinkForm(draft: draft) { url, text in composerHandle.link(url, text: text) }
        }
    }
    private var scope: String { store.key(conversation.id, thread) }
    /// While the composer quotes or edits, Esc is its own, to drop the quote or end the edit, before a pane's Esc.
    static func ownsEsc(_ store: ChatStore, _ scope: String) -> Bool {
        store.drafting.quoting[scope] != nil || store.drafting.editing[scope] != nil
    }
    private var pendingFiles: [Attachment] { store.drafting.attachments[scope] ?? [] }
    private func attach(_ urls: [URL]) { store.attach(urls, conversation: conversation.id, thread: thread) }
    private func chooseFiles() { ChatView.chooseFiles { attach($0) } }
    private var draft: String { store.drafting.text[scope] ?? "" }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingFiles.isEmpty
            || store.drafting.quoting[scope]?.forwardedFrom != nil
    }
    /// Floating glass pieces over the timeline, as Telegram lays them out: a round attach button, the field (with
    /// Aa, emoji and GIF at its end) and a round send button; the edit, reply, formatting, upload and typing rows
    /// float as small capsules above the field.
    private var composer: some View {
        FloatingGlassGroup {
            VStack(alignment: .leading, spacing: 6) {
                typingBubble  // under the timeline's avatars, which line up with the attach button
                Group {
                    if formatBar {
                        ComposerFormatBar(
                            composerHandle: composerHandle, currentColor: composerHandle.view?.currentColor
                        ).padding(.horizontal, -6).floatingCapsule()
                    }
                    ScheduledCapsule(conversation: conversation, thread: thread)
                    if store.uploading(conversation.id, thread: thread) > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                        }.floatingCapsule()
                    }
                    if !pendingFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(pendingFiles, id: \.self) {
                                    PendingFileChip(file: $0, conversation: conversation, thread: thread)
                                }
                            }.padding(4)
                        }
                    }
                }.padding(.leading, Self.control + 8)  // above the field, not the attach button
                HStack(alignment: .bottom, spacing: 8) {
                    if recorder.isRecording {  // Telegram's recording bar: ✕ cancels (Esc), the round button sends (Return)
                        Button {
                            recorder.cancel()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(
                                .secondary
                            )
                            .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), interactive: true)
                        }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cancel recording (Esc)")
                            .accessibilityLabel("Cancel recording")
                        RecordingBar(recorder: recorder).frame(maxWidth: .infinity, minHeight: Self.control)
                            .floatingGlass(RoundedRectangle(cornerRadius: Self.control / 2, style: .continuous))
                        Button(action: sendRecording) {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(
                                .white
                            )
                            .frame(width: Self.control, height: Self.control).floatingGlass(
                                Circle(), tint: .accentColor, interactive: true)
                        }.buttonStyle(.plain).keyboardShortcut(.defaultAction).help("Send voice message (Return)")
                            .accessibilityLabel("Send voice message")
                    } else {
                        Button(action: chooseFiles) {
                            Image(systemName: "paperclip").font(.system(size: 17)).foregroundStyle(.secondary)
                                .frame(width: Self.control, height: Self.control).floatingGlass(
                                    Circle(), interactive: true)
                        }.buttonStyle(.plain).help("Attach files").accessibilityLabel("Attach files")
                        field
                        if canSend || store.editingID(conversation.id, thread: thread) != nil {
                            Button {
                                Task { await store.send(conversation: conversation.id, thread: thread) }
                            } label: {
                                Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(canSend ? .white : .secondary)
                                    .frame(width: Self.control, height: Self.control)
                                    .floatingGlass(Circle(), tint: canSend ? .accentColor : nil, interactive: true)
                            }.buttonStyle(.plain).disabled(!canSend).help(
                                "Send message: Return. A new line: Shift-Return. Right-click to schedule."
                            ).accessibilityLabel("Send message")
                                .contextMenu {
                                    ScheduleMenu(
                                        enabled: store.canSchedule(conversation: conversation.id, thread: thread)
                                    ) { date in
                                        Task {
                                            await store.schedule(
                                                conversation: conversation.id, thread: thread, at: date)
                                        }
                                    } custom: {
                                        pickingSchedule = true
                                    }
                                }
                                .sheet(isPresented: $pickingSchedule) {
                                    ScheduleSheet(title: "Schedule Send") { date in
                                        pickingSchedule = false
                                        if let date {
                                            Task {
                                                await store.schedule(
                                                    conversation: conversation.id, thread: thread, at: date)
                                            }
                                        }
                                    }
                                }
                        } else {  // an empty field offers a voice message instead, as Telegram does
                            Button {
                                Task { do { try await recorder.start() } catch { store.report(error) } }
                            } label: {
                                Image(systemName: "mic").font(.system(size: 17)).foregroundStyle(.secondary)
                                    .frame(width: Self.control, height: Self.control).floatingGlass(
                                        Circle(), interactive: true)
                            }.buttonStyle(.plain).help("Record voice message").accessibilityLabel(
                                "Record voice message")
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
        }
    }
    /// Ends this composer's edit and clears the message's text from it.
    private func endEdit() { store.endEdit(conversation: conversation.id, thread: thread) }
    private func sendRecording() {
        guard let recording = recorder.finish() else { return }
        Task {
            await store.sendVoice(
                recording.file, duration: recording.duration, waveform: recording.levels, conversation: conversation.id,
                thread: thread)
        }
    }
    @State private var pickingSchedule = false
    private static let control: CGFloat = 42  // round buttons, and the field's height on one line
    @State private var fieldHeight: CGFloat = 0  // the text view's laid-out height; wrapped paragraphs count, not only newlines
    /// The text capsule: the native field, a placeholder while empty, and Aa, emoji and GIF at its end.
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerFieldHeader(conversation: conversation, thread: thread)
            fieldRow
        }
        .floatingGlass(RoundedRectangle(cornerRadius: Self.control / 2, style: .continuous))
    }
    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            NativeComposer(
                text: draft, formatting: store.drafting.formatting[scope] ?? [],
                change: { text, formatting in
                    store.setDraft(text, formatting: formatting, conversation: conversation.id, thread: thread)
                    Task { await store.typed(text, conversation: conversation.id, thread: thread) }
                }, send: { Task { await store.send(conversation: conversation.id, thread: thread) } },
                editLast: {
                    if let last = store.timeline(conversation.id, thread: thread).last(where: {
                        $0.sender.id == store.me.id
                    }) {
                        store.edit(last)
                    }
                },
                cancel: {  // Esc: drops the quote first, then ends an edit and closes the thread
                    if store.drafting.quoting[scope] != nil {
                        store.drafting.quoting[scope] = nil
                    } else if store.drafting.editing[scope] != nil {
                        endEdit()
                    } else if !detached {  // a thread window leaves the main window's panes alone
                        let closing = composerHandle.view
                        let window = closing?.window
                        store.navigation.setPane(paneWindow) {
                            $0.closeThread()
                            $0.closeInfo()
                        }
                        // Out of a thread: the conversation's composer has the keyboard again.
                        if thread != nil {
                            DispatchQueue.main.async {
                                if let main = ComposerTextView.all(in: window).first(where: { $0 !== closing }) {
                                    window?.makeFirstResponder(main)
                                }
                            }
                        }
                    }
                }, attach: attach,
                members: store.mentionSuggestions(conversation.id), spaces: store.rooms.conversations,
                needMembers: { Task { await store.loadMembers(conversation.id) } },
                // None where people outside the organisation take part: Google Chat refuses them there.
                customEmoji: store.allowsCustomEmoji(in: conversation.id) ? store.lookups.customEmoji : [],
                needCustomEmoji: {
                    if store.allowsCustomEmoji(in: conversation.id) { Task { await store.loadCustomEmoji() } }
                },
                searchCustomEmoji: { query in
                    if store.allowsCustomEmoji(in: conversation.id) { store.searchCustomEmoji(matching: query) }
                },
                directoryPeople: store.lookups.directoryPeople,
                mentionApps: store.lookups.apps[conversation.id] ?? Found(), driveFiles: store.lookups.driveFiles,
                needMentionResults: { store.searchMentionResults(conversation.id, $0) },
                slashCommands: store.lookups.slashCommands[conversation.id] ?? [],
                needSlashCommands: { query in Task { await store.loadSlashCommands(conversation.id, query: query) } },
                runCommand: { command in Task { await store.run(command, in: conversation.id) } },
                loadImage: { try await store.attachmentData($0, thumbnail: $1) },
                // A thread's composer takes the keyboard as it opens: a quoted message's id or the thread's, so plain text.
                focus: store.drafting.quoting[scope]?.id?.rawValue ?? thread?.rawValue, handle: composerHandle,
                height: { if fieldHeight != $0 { fieldHeight = $0 } }
            )
            .frame(minWidth: 60).frame(height: min(130, max(Self.control, fieldHeight)))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {  // aligned with the text view's inset and line padding
                    Text(ChatView.composerPrompt(conversation, thread: thread)).foregroundStyle(.tertiary).padding(
                        .leading, 13
                    ).padding(.top, 11).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            Button {
                formatBar.toggle()
            } label: {
                Text("Aa").font(.system(size: 14, weight: .semibold)).fixedSize().foregroundStyle(
                    formatBar ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).padding(.bottom, 13).help(formatBar ? "Hide formatting" : "Show formatting")
            .accessibilityLabel("Formatting")
            Button {
                emojiPicker.toggle()
            } label: {
                Image(systemName: "face.smiling").font(.system(size: 18)).foregroundStyle(
                    emojiPicker ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).padding(.bottom, 11).help("Emoji").accessibilityLabel("Emoji")
            .popover(isPresented: $emojiPicker, arrowEdge: .top) {
                composerHandle.emojiPicker(
                    custom: store.allowsCustomEmoji(in: conversation.id) ? { store.customEmojiNow() } : nil,
                    loadImage: { try await store.attachmentData($0, thumbnail: $1) },
                    close: { emojiPicker = false })
            }
            Button {
                gifPicker.toggle()
            } label: {
                Text("GIF").font(.system(size: 11, weight: .bold)).fixedSize().padding(.horizontal, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.5)).foregroundStyle(
                        gifPicker ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).padding(.bottom, 14).help("GIF").accessibilityLabel("GIF")
            .popover(isPresented: $gifPicker, arrowEdge: .top) {
                GifPicker(
                    pick: { gif in Task { await store.sendGif(gif, conversation: conversation.id, thread: thread) } },
                    close: { gifPicker = false })
            }
        }
        .padding(.trailing, 14)
    }
}

/// Add Link, as Mail's ⌘K asks: the text (the selection, if any) and the address.
struct LinkForm: View {
    struct Draft: Identifiable {
        let id = UUID()
        var text: String
    }
    let draft: Draft
    let add: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var address = ""
    /// The address as typed, with https:// when it has no scheme ("example.com").
    nonisolated static func url(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://" + trimmed
        return URL(string: full).flatMap { $0.host() != nil || $0.scheme == "mailto" ? $0 : nil }
    }
    var body: some View {
        Form {
            TextField("Text", text: $text, prompt: Text("Shown in the message"))
            TextField("Link", text: $address, prompt: Text("https://"))
        }
        .padding(20).frame(width: 380)
        .onAppear {
            text = draft.text
            if Self.url(draft.text) != nil, draft.text.contains(".") { address = draft.text }
        }
        .sheetButtons(
            "Add Link", enabled: Self.url(address) != nil, cancel: { dismiss() },
            confirm: {
                if let url = Self.url(address) {
                    add(url, text)
                    dismiss()
                }
            })
    }
}

extension ChatView {
    /// The empty composer's prompt, as Google Chat's: Ask Gemini asks Gemini, and with history off it says so.
    static func composerPrompt(_ conversation: Conversation, thread: ThreadID? = nil) -> String {
        if conversation.app == .gemini { return thread == nil ? "Ask Gemini…" : "Reply" }  // a session's thread replies
        return conversation.historyOff == true ? "History is off" : "Message"
    }
}
