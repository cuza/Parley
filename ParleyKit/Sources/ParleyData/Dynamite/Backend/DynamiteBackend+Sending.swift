import Foundation
import ParleyDomain
import SwiftProtobuf

extension DynamiteBackend {
    public func send(_ draft: MessageDraft, to conversation: ConversationID, thread: ThreadID?) async throws -> Message
    {
        let group = try DynamiteID.group(conversation)
        // Marker-free text plus our own FORMAT_DATA annotations, which the server keeps only with accept_format_annotations (Google Chat's send path).
        // A chip the draft held (written elsewhere) goes with it, as when saving the draft.
        let extras =
            draft.serverDraftID.flatMap { draftExtras[$0] }.map { old in
                old.annotations.compactMap { Self.relocated($0, from: old.text, to: draft.text) }
            } ?? []
        let chips = draft.serverDraftID.flatMap { draftExtras[$0]?.annotations } ?? []
        let formats = DynamiteMapper.annotations(
            Self.sendable(draft.formatting, besides: chips), outsiders: draft.outsiders)
        let formatted = !formats.isEmpty
        // Uploaded files (picked GIFs too) ride in the same field 3, as UPLOAD_METADATA chips.
        let uploads = draft.uploads.compactMap(DynamiteMapper.uploadAnnotation)
        guard uploads.count == draft.uploads.count else { throw DynamiteError.malformedReply }
        // A picked slash command goes as its annotation, and Google Chat then sends the format flag as well.
        let command = draft.formatting.compactMap(DynamiteMapper.slashCommand)
        let annotations = command + formats + uploads + extras
        do {
            return try await create(
                draft, annotations: annotations, formatted: formatted || !command.isEmpty, in: conversation,
                group: group, thread: thread)
        } catch {
            // The id is derived from the local id, so a retry whose first attempt reached the server is refused as a duplicate;
            // if that message has already arrived (pushed or loaded), the send did happen.
            let own = DynamiteID.messageID(for: draft.localID)
            let id = DynamiteID.message(
                conversation, topic: try thread.map { try DynamiteID.topic(of: $0.head) } ?? own, message: own)
            if let sent = thread.flatMap({ threads[$0]?.first { $0.id == id } })
                ?? heads[Self.topicKey(id)].flatMap({ $0.id == id ? $0 : nil })
            {
                return sent
            }
            throw error
        }
    }

    public func sendMeetLink(in conversation: ConversationID) async throws -> Message {
        let group = try DynamiteID.group(conversation)
        let made: Dynamite_CreateVideoCallResponse = try await rpc(
            "create_video_call",
            Dynamite_CreateVideoCallRequest.with {
                $0.groupID = group
            })
        guard made.hasAnnotation else { throw DynamiteError.malformedReply }
        return try await create(
            MessageDraft(text: "", localID: UUID().uuidString), annotations: [made.annotation], formatted: false,
            in: conversation, group: group, thread: nil)
    }

    private func create(
        _ draft: MessageDraft, annotations: [Dynamite_Annotation], formatted: Bool, in conversation: ConversationID,
        group: Dynamite_GroupId, thread: ThreadID?
    ) async throws -> Message {
        let proto: Dynamite_Message
        let quoted = try draft.quoting.flatMap(DynamiteMapper.quotedRef)
        // The draft this message was: Google Chat names it so the server drops it with the send.
        let unsent = try draft.serverDraftID.map {
            try DynamiteMapper.unsentID($0, conversation: conversation, thread: thread)
        }
        if let thread {
            let topic = try DynamiteID.topic(of: thread.head)
            let request = Dynamite_CreateMessageRequest.with { request in
                request.parentID.topicID.topicID = topic
                request.parentID.topicID.groupID = group
                request.textBody = draft.text
                request.messageID = DynamiteID.messageID(for: draft.localID)
                request.annotations = annotations
                if formatted { request.messageInfo.acceptFormatAnnotations = true }
                if let quoted { request.messageInfo.quotedMessage = quoted }
                if let unsent { request.messageInfo.unsentMessageID = unsent }
            }
            proto = (try await rpc("create_message", request) as Dynamite_CreateMessageResponse).message
        } else {
            let request = Dynamite_CreateTopicRequest.with { request in
                request.groupID = group
                request.textBody = draft.text
                request.topicAndMessageID = DynamiteID.messageID(for: draft.localID)
                request.historyV2 = true
                request.annotations = annotations
                request.messageInfo.acceptFormatAnnotations = formatted
                if let quoted { request.messageInfo.quotedMessage = quoted }
                if let unsent { request.messageInfo.unsentMessageID = unsent }
            }
            let response: Dynamite_CreateTopicResponse = try await rpc("create_topic", request)
            guard let first = response.topic.replies.first else { throw DynamiteError.malformedReply }
            proto = first
        }
        var placed = place(proto, in: conversation, isHead: thread == nil)  // a reply never becomes the head of a thread not loaded here
        guard !placed.isEmpty else { throw DynamiteError.malformedReply }
        placed[0].threadID = thread
        placed.dropFirst().forEach { continuation.yield(.messageUpserted($0)) }  // the head's new reply count
        return placed[0]
    }

    /// Google Chat's main composer types into the group, a thread's reply box into its topic.
    public func sendTyping(in conversation: ConversationID, thread: ThreadID?) async throws {
        let group = try DynamiteID.group(conversation)
        let request = try Dynamite_SetTypingStateRequest.with { request in
            request.state = .typing
            if let thread {
                request.context.topicID = try DynamiteID.topicID(of: thread.head, in: conversation)
            } else {
                request.context.groupID = group
            }
        }
        do {
            let _: Dynamite_SetTypingStateResponse = try await rpc("set_typing_state", request)
        } catch {
            // Which kind of conversation refused it; the id stays private.
            let kind = conversation.rawValue.split(separator: "/").first ?? "?"
            log.error(
                "typing not sent in a \(kind, privacy: .public)\(thread == nil ? "" : " thread", privacy: .public) (\(conversation, privacy: .private))"
            )
            throw error
        }
    }
    public func edit(_ id: MessageID, text: String, formatting: [TextStyleRange] = []) async throws {
        let request = try Dynamite_EditMessageRequest.with { request in
            request.messageID = try DynamiteID.protoMessageID(id)
            request.textBody = text
            // Google Chat edits only the text: the rest of the message's annotations go back as they are, or the server drops them.
            let formats = DynamiteMapper.annotations(
                Self.sendable(formatting, besides: attached[id]?.annotations ?? []))
            request.annotations =
                formats
                + (attached[id].map { old in old.annotations.filter { Self.survives($0, from: old.text, to: text) } }
                    ?? [])
            request.messageInfo.acceptFormatAnnotations = !formats.isEmpty
            if let quote = attached[id]?.quote { request.messageInfo.quotedMessage = quote }
        }
        if !seen.contains(id) {
            log.notice("Editing a message not loaded here: any attachments or quote it has are not re-sent")
        }
        let response: Dynamite_EditMessageResponse = try await rpc("edit_message", request)
        let conversation = DynamiteID.conversation(of: id)
        saw([response.message], in: conversation)
        if let thread = unloadedThread(of: response.message, in: conversation),
            var message = DynamiteMapper.message(response.message, in: conversation, selfID: selfID, people: people)
        {
            message.threadID = thread
            continuation.yield(.messageUpserted(message))
        } else {
            place(response.message, in: conversation).forEach { continuation.yield(.messageUpserted($0)) }
        }
    }
    public func deleteMessage(_ id: MessageID) async throws {
        let request = try Dynamite_DeleteMessageRequest.with { request in
            request.messageID = try DynamiteID.protoMessageID(id)
        }
        let _: Dynamite_DeleteMessageResponse = try await rpc("delete_message", request)
        deleted(id)
    }
    /// `apply_message_label` / `remove_message_label` with the PINNED label, as Google Chat's Pin to board and Unpin send them:
    /// a pin also sends position 0.
    public func setBoardPinned(_ pinned: Bool, for id: MessageID) async throws {
        try await setLabel(.pinned, pinned, on: id)
        update(id) { $0.pinned = pinned }
    }
    /// `apply_message_label` / `remove_message_label` with the STAR label, as Google Chat's Star and Unstar send them.
    public func setStarred(_ starred: Bool, for id: MessageID) async throws {
        try await setLabel(.star, starred, on: id)
        update(id) { $0.starred = starred }
    }
    private func setLabel(_ type: Dynamite_MessageLabel.TypeEnum, _ applied: Bool, on id: MessageID) async throws {
        let request = try Dynamite_MessageLabelRequest.with { request in
            request.messageID = try DynamiteID.protoMessageID(id)
            request.label.type = type
            if applied, type == .pinned { request.label.position = 0 }
        }
        if applied {
            let _: Dynamite_ApplyMessageLabelResponse = try await rpc("apply_message_label", request)
        } else {
            let _: Dynamite_RemoveMessageLabelResponse = try await rpc("remove_message_label", request)
        }
    }
    /// Links the message or draft already has as annotations of its own (a space chip, a link Google Chat detected or one
    /// sent before) show as links in the composer: they go as those annotations (or not at all, once their text is gone),
    /// never again as new links.
    static func sendable(_ formatting: [TextStyleRange], besides chips: [Dynamite_Annotation]) -> [TextStyleRange] {
        let chipLinks = Set(
            chips.compactMap { chip -> URL? in
                switch chip.metadata {
                case .groupMetadata(let group)?: DynamiteID.conversation(group.groupID).map(ChatLink.url)
                case .urlMetadata(let link)?: URL(string: link.url.url)
                default: nil
                }
            })
        let chipRooms = Set(
            chips.compactMap { chip -> ConversationID? in
                guard case .groupMetadata(let group)? = chip.metadata else { return nil }
                return DynamiteID.conversation(group.groupID)
            })
        return formatting.filter { range in
            switch range.style {
            case .link(let url): !chipLinks.contains(url)
            case .chip(let room, _, _): !chipRooms.contains(room)
            default: true
            }
        }
    }

    /// `annotation` over the same text in `new`: in place, else moved to that text's only occurrence; nil when it's gone.
    static func relocated(_ annotation: Dynamite_Annotation, from old: String, to new: String) -> Dynamite_Annotation? {
        if survives(annotation, from: old, to: new) { return annotation }
        let start = Int(annotation.startIndex)
        let end = start + Int(annotation.length)
        let old = Array(old.utf16)
        let new = Array(new.utf16)
        guard start >= 0, end <= old.count, end > start else { return nil }
        let text = Array(old[start..<end])
        let found = new.indices.filter { $0 + text.count <= new.count && Array(new[$0..<($0 + text.count)]) == text }
        guard found.count == 1 else { return nil }
        var moved = annotation
        moved.startIndex = Int32(found[0])
        return moved
    }

    /// An annotation with no text range (an upload, a Drive file) always survives an edit; one over the text (a link preview,
    /// a space chip) only while that text is unchanged at the same place, since its range would otherwise point at other text.
    static func survives(_ annotation: Dynamite_Annotation, from old: String, to new: String) -> Bool {
        guard annotation.length > 0 else { return true }
        let start = Int(annotation.startIndex)
        let end = start + Int(annotation.length)
        let old = Array(old.utf16)
        let new = Array(new.utf16)
        return start >= 0 && end <= min(old.count, new.count) && old[start..<end] == new[start..<end]
    }
    /// No HTTP cache: Google Chat gives a picture a new URL on every load, so none would ever be reused; `ImageCache`
    /// keeps pictures by message instead.
    static func mediaConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        return config
    }

    public func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data {
        guard
            let url = thumbnail ? attachment.thumbnailURL ?? attachment.url : attachment.url ?? attachment.thumbnailURL
        else {
            throw DynamiteError.notYetSupported("This attachment")
        }
        return try await authorizer.mediaData(from: url, session: media)
    }

    /// A Scotty resumable upload over the web session: `start` on chat.google.com/uploads,
    /// then one `upload, finalize` PUT to the session URL it returns. Both go through `WebSessionAuthorizer`, so they carry the
    /// session's cookies and XSRF token and only ever reach https://chat.google.com. The reply is a base64 UploadMetadata,
    /// kept whole as the attachment's `uploadToken` for `send`.
    public func upload(_ attachment: Attachment, to conversation: ConversationID, thread: ThreadID?) async throws
        -> Attachment
    {
        guard let file = attachment.url, file.isFileURL else { throw DynamiteError.notYetSupported("This attachment") }
        let group = try DynamiteID.group(conversation)
        // Too large is known from the file's size, before reading it (on a network volume, a read is a full copy).
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Attachment.maxUploadBytes {
            throw AttachmentError.tooLarge(attachment.name)
        }
        // ponytail: the whole file in one request (memory-mapped); chunk with `upload` commands if 200 MB proves too much.
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !bytes.isEmpty else { throw AttachmentError.empty(attachment.name) }
        guard bytes.count <= Attachment.maxUploadBytes else { throw AttachmentError.tooLarge(attachment.name) }
        var query = [
            URLQueryItem(
                name: "group_id", value: group.spaceID.spaceID.isEmpty ? group.dmID.dmID : group.spaceID.spaceID)
        ]
        if let thread { query.append(URLQueryItem(name: "topic_id", value: try DynamiteID.topic(of: thread.head))) }
        var components = URLComponents(string: "https://chat.google.com/uploads")!
        components.queryItems = query
        var start = URLRequest(url: components.url!)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(
            attachment.name.filter { $0 != "\r" && $0 != "\n" }, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        start.setValue(String(bytes.count), forHTTPHeaderField: "X-Goog-Upload-Content-Length")
        if !attachment.contentType.isEmpty {
            start.setValue(attachment.contentType, forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        }
        let (_, started) = try await authorized(start)
        guard started.value(forHTTPHeaderField: "X-Goog-Upload-Status")?.lowercased() == "active",
            let session = started.value(forHTTPHeaderField: "X-Goog-Upload-URL").flatMap(URL.init(string:))
        else {
            throw AuthFailure.unexpectedResponse
        }
        var put = URLRequest(url: session)
        put.httpMethod = "PUT"
        put.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        put.httpBody = bytes
        let (body, finished) = try await authorized(put)
        guard finished.value(forHTTPHeaderField: "X-Goog-Upload-Status")?.lowercased() == "final",
            let metadata = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
            let decoded = try? Dynamite_UploadMetadata(serializedBytes: metadata), !decoded.attachmentToken.isEmpty
        else {
            throw DynamiteError.malformedReply
        }
        var uploaded = attachment
        uploaded.uploadToken = metadata.base64EncodedString()
        return uploaded
    }
}
