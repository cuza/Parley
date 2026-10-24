import Foundation
import OSLog
import ParleyDomain

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

extension ChatStore {
    /// Posts a new Google Meet meeting in the conversation; its link, to open, or nil when refused (the error shows).
    func sendMeetLink(in id: ConversationID) async -> URL? {
        do {
            let message = try await backend.sendMeetLink(in: id)
            upsert(message)
            return message.attachments.first { $0.kind == .call }?.url
        } catch {
            report(error)
            return nil
        }
    }
    /// Adds files to the draft; ones Google Chat would refuse (folders, empty, over 200 MB) are reported and left out.
    func attach(_ urls: [URL], conversation: ConversationID, thread: ThreadID?) {
        let scope = key(conversation, thread)
        var refused: [String] = []
        for url in urls {
            do { drafting.attachments[scope, default: []].append(try .localFile(at: url)) } catch {
                refused.append(error.localizedDescription)
            }
        }
        if !refused.isEmpty { error = refused.joined(separator: "\n") }
    }
    func detach(_ attachment: Attachment, conversation: ConversationID, thread: ThreadID?) {
        drafting.attachments[key(conversation, thread)]?.removeAll { $0 == attachment }
    }
    /// `adding`: my answer to `addPrompts` when the draft mentions people who aren't members; nil asks first.
    func send(conversation: ConversationID, thread: ThreadID? = nil, adding: Bool? = nil) async {
        let scope = key(conversation, thread)
        if drafting.addPrompts[scope] != nil { drafting.addPrompts[scope] = nil }  // only a change: every composer reads it
        let (text, formatting) = Self.trimmed(drafting.text[scope, default: ""], drafting.formatting[scope] ?? [])
        if let editingID = drafting.editing[scope] {
            guard !text.isEmpty else { return }
            do {
                try await backend.edit(editingID, text: text, formatting: formatting)
                finishEdit(scope)
            } catch {
                report(error)
            }
            return
        }
        let files = drafting.attachments[scope] ?? []
        guard !text.isEmpty || !files.isEmpty || drafting.quoting[scope]?.forwardedFrom != nil else { return }  // a forward needs no note
        var outsiders = outsiders(formatting, in: conversation)
        let invited = formatting.filter {
            if case .mention(let id?) = $0.style { outsiders[id] == .invite } else { false }
        }
        if !invited.isEmpty {
            switch adding {
            case nil:
                var names: [String] = []
                for range in invited {
                    let name = (text as NSString).substring(with: NSRange(location: range.start, length: range.length))
                    let plain = name.hasPrefix("@") ? String(name.dropFirst()) : name
                    if !names.contains(plain) { names.append(plain) }
                }
                drafting.addPrompts[scope] = names
                return
            case false?: outsiders = outsiders.mapValues { _ in .reference }  // named in the message, not added
            case true?: break
            }
        }
        setDraft("", conversation: conversation, thread: thread)
        drafting.attachments[scope] = nil
        let quote = drafting.quoting.removeValue(forKey: scope)
        // The send names the draft, and the server drops it; nothing is left to save here.
        let draft = drafting.spend(scope)
        await sendNew(
            text, formatting: formatting, attachments: files, quote: quote, serverDraft: draft, outsiders: outsiders,
            conversation: conversation, thread: thread)
        sent?(conversation)
    }
    /// Sends a picked GIF on its own, quoting the message being replied to, as Google Chat does; the local echo shows it as an
    /// image attachment. Sent as an upload: the server drops a client-made URL chip for GIPHY links and stores an empty message.
    func sendGif(_ gif: Attachment, conversation: ConversationID, thread: ThreadID? = nil) async {
        guard let url = gif.url else { return }
        do {
            let name = (gif.name.isEmpty ? "GIF" : gif.name).replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name + ".gif")
            try await download(url).write(to: file)
            await sendNew(
                "", attachments: [try .localFile(at: file)],
                quote: drafting.quoting.removeValue(forKey: key(conversation, thread)),
                conversation: conversation, thread: thread)
        } catch { report(error) }
    }
    /// Sends a recording on its own (quoting the message being replied to), as Google Chat does: an upload named and typed like its own recordings, with the voice metadata.
    func sendVoice(
        _ file: URL, duration: TimeInterval, waveform: [Int], conversation: ConversationID, thread: ThreadID? = nil
    ) async {
        let voice = Attachment(
            name: file.lastPathComponent, contentType: Voice.contentType, kind: .voice, url: file,
            voice: Voice(duration: duration, waveform: waveform))
        await sendNew(
            "", attachments: [voice], quote: drafting.quoting.removeValue(forKey: key(conversation, thread)),
            conversation: conversation, thread: thread)
    }
    /// A notification's inline reply: sent without touching the draft, and the conversation counts as read, as Messages does.
    func reply(_ text: String, conversation: ConversationID, thread: ThreadID?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await sendNew(text, conversation: conversation, thread: thread)
        await markRead(conversation)
    }
    /// Shortcuts' and Siri's Send Message: plain text to one of my conversations, as if typed in its composer. True once
    /// Google has it; false for empty text, a conversation I'm not in, or a send that failed (left as failed in the timeline).
    func sendText(_ text: String, to conversation: ConversationID) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, rooms.conversations.contains(where: { $0.id == conversation }) else { return false }
        let id = await sendNew(text, conversation: conversation, thread: nil)
        return !history.messages.contains { $0.id == id && $0.delivery == .failed }
    }
    @discardableResult
    func sendNew(
        _ text: String, formatting: [TextStyleRange] = [], attachments: [Attachment] = [], quote: QuotedMessage? = nil,
        serverDraft: String? = nil, outsiders: [PersonID: MessageDraft.Outsider] = [:],
        conversation: ConversationID, thread: ThreadID?
    ) async -> MessageID {
        if thread == nil, history.detached.contains(conversation) { await returnToNewest(conversation) }  // a send lands at the bottom, as on the web
        let pending = Message(
            id: MessageID("local-\(UUID())"), conversationID: conversation, threadID: thread, sender: me, text: text,
            delivery: .pending, attachments: attachments, formatting: formatting, quote: quote)
        upsert(pending)
        if !outsiders.isEmpty { drafting.sendOutsiders[pending.id] = outsiders }
        await deliver(pending, serverDraft: serverDraft)
        return pending.id
    }
    /// The draft without surrounding whitespace, its ranges shifted and clipped to match (UTF-16 offsets).
    static func trimmed(_ text: String, _ formatting: [TextStyleRange]) -> (String, [TextStyleRange]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let found = text.range(of: trimmed) else { return (trimmed, []) }
        let lead = text.utf16.distance(from: text.startIndex, to: found.lowerBound)
        let count = trimmed.utf16.count
        return (
            trimmed,
            formatting.compactMap { range in
                let start = max(0, range.start - lead)
                let end = min(count, range.start + range.length - lead)
                return end > start ? TextStyleRange(style: range.style, start: start, length: end - start) : nil
            }
        )
    }
    /// Mentions of people who aren't members, decided as Google Chat decides them on send: in a space or group where I
    /// may add people, the mention invites them; elsewhere (a 1:1 DM, or without that right) it only names them. Nothing
    /// is decided until the full member list is known, so a member is never invited.
    private func outsiders(_ formatting: [TextStyleRange], in id: ConversationID) -> [PersonID: MessageDraft.Outsider] {
        guard let conversation = self.conversation(id) else { return [:] }
        return Self.outsiders(
            formatting, members: rooms.members[id], kind: conversation.kind,
            canAdd: rooms.permissions[id]?.manageMembers == true)
    }
    static func outsiders(_ formatting: [TextStyleRange], members: [Person]?, kind: ConversationKind, canAdd: Bool)
        -> [PersonID: MessageDraft.Outsider]
    {
        guard let members else { return [:] }
        let known = Set(members.map(\.id))
        var found: [PersonID: MessageDraft.Outsider] = [:]
        for range in formatting {
            guard case .mention(let id?) = range.style, id != TextStyleRange.everyone, !known.contains(id) else {
                continue
            }
            found[id] = kind != .direct && canAdd ? .invite : .reference
        }
        return found
    }
    // ponytail: a retry no longer names the draft; if the send never reached Google, its draft comes back at the next launch.
    /// Uploads the echo's local files first, keeping each finished upload on the echo so a retry only redoes what failed.
    private func deliver(_ pending: Message, serverDraft: String? = nil) async {
        var pending = pending
        // Google refuses a quote of a deleted message (HTTP 404) however often it's sent: the message goes without it.
        if let quoted = pending.quote?.id, history.messages.contains(where: { $0.id == quoted && $0.tombstone }) {
            pending.quote = nil
        }
        do {
            for (index, file) in pending.attachments.enumerated() where file.isLocalFile && file.uploadToken == nil {
                pending.attachments[index] = try await backend.upload(
                    file, to: pending.conversationID, thread: pending.threadID)
                upsert(pending)
            }
            let sent = try await backend.send(
                MessageDraft(
                    text: pending.text, localID: pending.id.rawValue, formatting: pending.formatting,
                    uploads: pending.attachments.filter(\.isLocalFile), quoting: pending.quote,
                    serverDraftID: serverDraft, outsiders: drafting.sendOutsiders[pending.id] ?? [:]),
                to: pending.conversationID, thread: pending.threadID)
            drafting.sendOutsiders[pending.id] = nil
            history.messages.removeAll { $0.id == pending.id }
            upsert(sent)
            // A command that opens a dialog: the app's dialog for the command's message, as Google Chat asks for it.
            if let command = pending.formatting.lazy.compactMap({
                if case .slashCommand(let command) = $0.style { command } else { nil }
            }).first,
                command.opensDialog
            {
                await openDialog(
                    DialogContext(message: sent.id, app: command.appID), app: command.appName, in: sent.conversationID,
                    action: nil, inputs: [])
            }
        } catch {
            log.error("send failed: \(Redaction.redact(String(describing: error)), privacy: .public)")
            var failed = pending
            failed.delivery = .failed
            upsert(failed)
            _ = endedSession(error)
        }
        persist()
    }
    func retry(_ message: Message) async {
        guard message.delivery == .failed else { return }
        var pending = message
        pending.delivery = .pending
        upsert(pending)
        await deliver(pending)
    }
    /// Quote-replies to `message` from its own composer (the conversation's, or its thread's); ends an edit there.
    func quote(_ message: Message) {
        guard message.delivery == .sent, !message.isSystem, !message.tombstone else { return }
        finishEdit(key(message.conversationID, message.threadID))
        drafting.quoting[key(message.conversationID, message.threadID)] = quotation(of: message)
    }
    /// `message` as a quote or forward names it. Without a server update time it names the create time.
    private func quotation(of message: Message) -> QuotedMessage {
        QuotedMessage(
            sender: message.sender.name,
            text: QuotedMessage.summary(
                text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments),
            id: message.id,
            lastUpdateMicros: message.lastUpdateMicros
                ?? Int64((message.createdAt.timeIntervalSince1970 * 1_000_000).rounded()),
            media: message.attachments.first { $0.kind == .image || $0.kind == .video })
    }
    /// Send to Parley: the text joins `conversation`'s draft on a line of its own and the files attach to it; nothing is sent.
    func share(_ shared: Shared, to conversation: ConversationID) {
        let scope = key(conversation, nil)
        let draft = drafting.text[scope] ?? ""
        if !shared.text.isEmpty {
            setDraft(
                draft.isEmpty ? shared.text : draft + "\n" + shared.text, formatting: drafting.formatting[scope] ?? [],
                conversation: conversation, thread: nil)
        }
        attach(shared.files, conversation: conversation, thread: nil)
    }
    /// Forward…: `message` waits above `destination`'s composer, as in Google Chat, and goes with the next send there.
    func forward(_ message: Message, to destination: ConversationID) {
        guard message.delivery == .sent, !message.isSystem else { return }
        var forward = quotation(of: message)
        forward.forwardedFrom = conversation(message.conversationID)?.name ?? "a conversation"
        drafting.quoting[key(destination, nil)] = forward
    }
    /// Messages in this timeline still uploading their files; the composer says so.
    func uploading(_ conversation: ConversationID, thread: ThreadID? = nil) -> Int {
        timeline(conversation, thread: thread).filter {
            $0.delivery == .pending && $0.attachments.contains { $0.isLocalFile && $0.uploadToken == nil }
        }.count
    }
}
