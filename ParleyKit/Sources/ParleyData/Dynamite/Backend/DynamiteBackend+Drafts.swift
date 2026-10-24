import Foundation
import ParleyDomain

extension DynamiteBackend {
    // Server drafts and scheduled messages are Google Chat's unsent messages of type DRAFT and SCHEDULED. Their four RPCs
    // carry the request header at field 1.
    public func drafts() async throws -> [ServerDraft] {
        try await unsent(.draft, scope: 0).filter { $0.schedule == nil }
    }
    public func scheduled() async throws -> [ServerDraft] {
        try await unsent(.scheduled, scope: 1).filter { $0.schedule != nil }
    }
    // ponytail: stops after 10 pages; raise it if anyone keeps that many drafts.
    /// `list_unsent_messages` as Google Chat's start-up asks for each type: filter {type, 5: 0 for drafts, 1 for scheduled},
    /// an empty paging field, then each page's token.
    private func unsent(_ type: Dynamite_UnsentMessage.TypeEnum, scope: Int32) async throws -> [ServerDraft] {
        var drafts: [ServerDraft] = []
        var token: String?
        for _ in 0..<10 {
            let request = Dynamite_ListUnsentMessagesRequest.with { request in
                request.paging = .init()
                if let token { request.paging.pageToken = token }
                request.filter.type = type
                request.filter.scope = scope
            }
            let response: Dynamite_ListUnsentMessagesResponse = try await rpc("list_unsent_messages", request)
            response.unsentMessages.forEach(keepUneditable)
            drafts += response.unsentMessages.compactMap(DynamiteMapper.draft)
            guard !response.nextPageToken.isEmpty, response.nextPageToken != token else { break }
            token = response.nextPageToken
        }
        return drafts
    }
    /// As Google Chat's composer saves: `create_unsent_message` with a client-chosen id, type DRAFT and a new mutation id;
    /// later `update_unsent_message` with the whole text and the mask Google Chat sends (mutation id, text, annotations, quote).
    /// A draft with a `schedule` is created as Google Chat schedules a message: type SCHEDULED, the time, an empty mutation id.
    public func saveDraft(_ draft: ServerDraft) async throws -> ServerDraft {
        let creating = draft.id.isEmpty
        let unsent = try Dynamite_UnsentMessage.with { message in
            message.id = try DynamiteMapper.unsentID(
                creating ? DynamiteID.messageID(for: UUID().uuidString) : draft.id,
                conversation: draft.conversationID, thread: draft.threadID)
            message.textBody = draft.text
            let extras =
                draftExtras[draft.id].map { old in
                    old.annotations.compactMap { Self.relocated($0, from: old.text, to: draft.text) }
                } ?? []
            message.annotations =
                DynamiteMapper.annotations(
                    Self.sendable(draft.formatting, besides: draftExtras[draft.id]?.annotations ?? [])) + extras
            if let schedule = draft.schedule, creating {
                message.type = .scheduled
                message.scheduledSend.sendTime.seconds = Int64(schedule.at.timeIntervalSince1970.rounded())
                message.mutationID = ""
            } else {
                if creating { message.type = .draft }
                message.mutationID = UUID().uuidString  // uppercase, as Google Chat sends it
            }
        }
        let saved: Dynamite_UnsentMessage
        if creating {
            let response: Dynamite_CreateUnsentMessageResponse = try await rpc(
                "create_unsent_message",
                Dynamite_CreateUnsentMessageRequest.with {
                    $0.unsentMessage = unsent
                })
            saved = response.unsentMessage
        } else {
            let response: Dynamite_UpdateUnsentMessageResponse = try await rpc(
                "update_unsent_message",
                Dynamite_UpdateUnsentMessageRequest.with {
                    $0.unsentMessage = unsent
                    $0.updateMask.fields = [9, 4, 5, 6]
                })
            saved = response.unsentMessage
        }
        log.notice(
            "\(draft.schedule == nil ? "draft" : "scheduled message", privacy: .public) \(creating ? "created" : "updated", privacy: .public)"
        )
        var result = draft
        result.id = unsent.id.id
        draftExtras[result.id] = draftExtras[draft.id].map { _ in
            (draft.text, unsent.annotations.filter(Self.uneditable))
        }
        result.updatedAt = DynamiteMapper.time(saved.updateTime) ?? .now
        return result
    }
    func keepUneditable(_ unsent: Dynamite_UnsentMessage) {
        let kept = unsent.annotations.filter(Self.uneditable)
        draftExtras[unsent.id.id] = kept.isEmpty ? nil : (unsent.textBody, kept)
    }
    static func uneditable(_ annotation: Dynamite_Annotation) -> Bool {
        switch annotation.metadata {
        case .formatMetadata, .userMentionMetadata, .customEmojiMetadata: false
        default: true
        }
    }
    /// As Google Chat reschedules: `update_unsent_message` with only the id and the new time, and a mask naming field 8's field 1.
    public func reschedule(_ message: ServerDraft, to date: Date) async throws -> ServerDraft {
        let request = try Dynamite_UpdateUnsentMessageRequest.with {
            $0.unsentMessage.id = try DynamiteMapper.unsentID(
                message.id, conversation: message.conversationID, thread: message.threadID)
            $0.unsentMessage.scheduledSend.sendTime.seconds = Int64(date.timeIntervalSince1970.rounded())
            $0.updateMask.paths = [
                .with {
                    $0.field = 8
                    $0.sub.fields = [1]
                }
            ]
        }
        let _: Dynamite_UpdateUnsentMessageResponse = try await rpc("update_unsent_message", request)
        log.notice("scheduled message rescheduled")
        var moved = message
        moved.schedule = .init(at: date)
        return moved
    }
    public func deleteDraft(_ draft: ServerDraft) async throws {
        let request = try Dynamite_DeleteUnsentMessageRequest.with {
            $0.id = try DynamiteMapper.unsentID(draft.id, conversation: draft.conversationID, thread: draft.threadID)
        }
        let _: Dynamite_DeleteUnsentMessageResponse = try await rpc("delete_unsent_message", request)
        log.notice("draft deleted")
    }
}
