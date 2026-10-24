import Foundation
import ParleyDomain

extension DynamiteBackend {
    public func setReaction(_ emoji: String, custom: CustomEmoji?, for id: MessageID, present: Bool) async throws {
        let request = try Dynamite_UpdateReactionRequest.with { request in
            request.messageID = try DynamiteID.protoMessageID(id)
            request.emoji = DynamiteMapper.emoji(emoji, custom: custom)
            request.option = present ? .add : .remove
        }
        let _: Dynamite_UpdateReactionResponse = try await rpc("update_reaction", request)
        // Shown now; the server's BATCH_REACTIONS_UPDATED that follows re-sends this emoji's count.
        update(id) { [selfID] in $0.reactions = Self.toggled($0.reactions, emoji, custom, by: selfID, present: present)
        }
    }
    /// `list_reactors` as Google Chat's reactor list sends it: one emoji, 100 people, no paging.
    public func reactors(of id: MessageID, emoji: String, custom: CustomEmoji?) async throws -> [Person] {
        let request = try Dynamite_ListReactorsRequest.with { request in
            request.messageID = try DynamiteID.protoMessageID(id)
            request.emoji = DynamiteMapper.emoji(emoji, custom: custom)
            request.pageSize = 100
        }
        let response: Dynamite_ListReactorsResponse = try await rpc("list_reactors", request)
        let ids = response.reactors.map(\.id).filter { !$0.isEmpty }
        await resolve(ids)
        return ids.map { people[$0] ?? Person(id: PersonID($0), name: "Unknown") }
    }
    static func toggled(
        _ reactions: [Reaction], _ emoji: String, _ custom: CustomEmoji?, by reactor: String, present: Bool
    ) -> [Reaction] {
        var reactions = reactions
        let person = PersonID(reactor)
        if let index = reactions.firstIndex(where: { $0.emoji == emoji && $0.custom?.id == custom?.id }) {
            if present {
                reactions[index].people.insert(person)
            } else if reactions[index].people.remove(person) == nil,  // known only by count: one placeholder goes instead
                let filler = reactions[index].people.first(where: { $0.rawValue.hasPrefix("reactor-") })
            {
                reactions[index].people.remove(filler)
            }
        } else if present {
            reactions.append(Reaction(emoji: emoji, people: [person], custom: custom))
        }
        return reactions.filter { !$0.people.isEmpty }
    }
    /// `click_card`, as Google Chat sends a card button's action: the message, the action as the button carried it, every
    /// input of the card, the card's id. The app answers with the message, its card updated, or with nothing (its answer
    /// comes as a new message); a refusal (status 4, with why) throws `DynamiteError.appRefused`.
    public func clickCard(_ id: MessageID, card: String?, action: Data, inputs: [Card.Input]) async throws -> Message? {
        let request = try Dynamite_ClickCardRequest.with { request in
            request.messageID = try DynamiteID.protoMessageID(id)
            request.action = action
            request.formInputs = inputs.map { input in
                .with {
                    $0.name = input.name
                    $0.value = input.value
                    $0.field4 = 1
                }
            }
            request.cardID = card ?? ""
        }
        let response: Dynamite_ClickCardResponse = try await rpc("click_card", request)
        if response.hasField1, response.field1 != 1 { throw DynamiteError.appRefused(response.status.message) }
        guard response.hasMessage else { return nil }
        let conversation = DynamiteID.conversation(of: id)
        return place(response.message, in: conversation).first
    }
    /// A dialog's requests, as Google Chat sends them: `submit_form_action` type 3 with the card button's action and
    /// the card's inputs to open one, type 1 with the pressed button's action and every input to submit, type 2 with
    /// nothing else to close it; `invoke_dialog` for a slash command's (no action). A quick command's requests name
    /// its conversation and the command where the others name a message. On close the app's answer is not read: Google
    /// Chat closes the dialog whatever it says.
    public func dialog(_ step: DialogStep, _ context: DialogContext, action: Data?, inputs: [Card.Input]) async throws
        -> DialogAnswer
    {
        let app = Dynamite_UserId.with {
            $0.id = context.app.rawValue
            $0.type = .bot
        }
        var message: Dynamite_MessageId?
        var group: Dynamite_GroupId?
        var command: Dynamite_AppCommandRef?
        switch context.source {
        case .message(let id): message = try DynamiteID.protoMessageID(id)
        case .command(let id, let conversation):
            group = try DynamiteID.group(conversation)
            command = .with {
                $0.id = Int32(truncatingIfNeeded: id)
                $0.kind = 2
                $0.invocation = 2
            }
        }
        if step == .open, action == nil {
            let response: Dynamite_InvokeDialogResponse = try await rpc(
                "invoke_dialog",
                Dynamite_InvokeDialogRequest.with { request in
                    if let message { request.messageID = message }
                    request.appID = app
                    if let group, let command {
                        request.groupID = group
                        request.command = command
                    }
                })
            // A quick command's anchor is its conversation, which links to no message, so its card links get none.
            return Self.answer(
                setup: response.hasSetup ? response.setup : nil, status: response.status,
                dialog: response.hasDialog ? response.dialog : nil, url: response.url,
                message: MessageID(context.anchor))
        }
        let request = Dynamite_SubmitFormActionRequest.with { request in
            request.type =
                switch step {
                case .open: 3
                case .submit: 1
                case .cancel: 2
                }
            if let message { request.messageID = message }
            request.appID = app
            if step != .cancel, let action { request.action = action }
            if step != .cancel {
                request.formInputs = inputs.map { input in
                    .with {
                        $0.name = input.name
                        $0.value = input.value
                        $0.field4 = 1
                    }
                }
            }
            if let group, let command {
                request.groupID = group
                request.command = command
            }
        }
        let response: Dynamite_SubmitFormActionResponse = try await rpc("submit_form_action", request)
        if step == .cancel { return .close(nil) }
        return Self.answer(
            setup: response.hasSetup ? response.setup : nil, status: response.status,
            dialog: response.hasDialog ? response.dialog : nil, url: response.url, message: MessageID(context.anchor))
    }
    /// An app's answer to a dialog request: set up first or sign in (its page, from the setup or in place of the
    /// dialog), what's wrong (a status other than OK), the next card, or done (with the status's note).
    static func answer(
        setup: Dynamite_DialogSetup?, status: Dynamite_ActionStatus, dialog: Dynamite_Card?, url: String = "",
        message: MessageID
    ) -> DialogAnswer {
        for page in [setup?.setupURL ?? "", url] {
            if let link = URL(string: page), link.scheme == "https" { return .configure(link) }
        }
        if status.code != 0 { return .invalid(status.message) }
        if let dialog { return .show(DynamiteMapper.dialog(dialog, message: message)) }
        return .close(status.message.isEmpty ? nil : status.message)
    }

    public func searchSlashCommands(in conversation: ConversationID, matching query: String, toApp: Bool) async throws
        -> [SlashCommand]
    {
        let request = DynamiteMapper.slashCommandSearch(query, in: try DynamiteID.group(conversation), toApp: toApp)
        let response: Dynamite_SearchIntegrationActionsResponse = try await rpc("search_integration_actions", request)
        return DynamiteMapper.slashCommands(response)
    }
    /// The organisation's emoji as Google Chat's web pages them: `list_custom_emojis`, 100 a page, the first with filters
    /// for enabled (and system-disabled) ones, each later one with the previous answer's page token and the validation token
    /// (an answer's field 4, back as field 5); without it a second page answers HTTP 400. Only enabled ones can be sent; a
    /// later copy of one replaces it. A page that fails after the first keeps what came before; a first page that fails
    /// throws, so it's asked again. Each read logs what it found, in numbers only (`CustomEmojiTally`).
    /// Reads every page: it stops when there's no next page, a page token repeats or a page brings nothing new.
    public func customEmojis() async throws -> [CustomEmoji] {
        var order: [String] = []
        var byID: [String: CustomEmoji] = [:]
        var seen: Set<String> = []
        var tally = CustomEmojiTally()
        var token = ""
        var validation = ""
        func done(_ end: String) -> [CustomEmoji] {
            let kept = order.compactMap { byID[$0] }
            log.notice("\(tally.line(kept: kept.count, end: end), privacy: .public)")
            return kept
        }
        var page = 0
        while true {
            page += 1
            let request = Dynamite_ListCustomEmojisRequest.with { request in
                request.pageSize = 100
                if page == 1 {
                    request.filters = Self.customEmojiFilters
                } else {
                    request.pageToken = token
                    if !validation.isEmpty { request.validationToken = validation }
                }
            }
            let response: Dynamite_ListCustomEmojisResponse
            do { response = try await rpc("list_custom_emojis", request) } catch {
                let line = done("page \(page) failed: \(CustomEmojiTally.kind(of: error))")
                if page == 1 { throw error }
                return line
            }
            tally.add(response.customEmojis)
            var unseen = 0  // any state: a page of disabled ones is still news
            for proto in response.customEmojis {
                let id = proto.uuid.isEmpty ? proto.shortcode : proto.uuid
                if seen.insert(id).inserted { unseen += 1 }
                guard proto.state == .enabled, let emoji = DynamiteMapper.customEmoji(proto) else {
                    byID[id] = nil
                    continue
                }
                if byID.updateValue(emoji, forKey: id) == nil { order.append(id) }
            }
            if page > 1, unseen == 0 { return done("a page brought nothing new") }
            if !response.validationToken.isEmpty { validation = response.validationToken }
            guard !response.nextPageToken.isEmpty else { return done("done") }
            guard response.nextPageToken != token else { return done("a page token came back twice") }
            token = response.nextPageToken
        }
    }
    public func searchApps(in conversation: ConversationID, matching query: String) async throws -> [Person] {
        let response: Dynamite_AutocompleteBotsResponse = try await rpc(
            "autocomplete_bots",
            Dynamite_AutocompleteBotsRequest.with { request in
                request.query = query
                request.maxResults = 4
                request.appFilters = [3]  // the conversation's own: a mention never adds an app
                request.groupID = try DynamiteID.group(conversation)
            })
        return response.bots.filter { !$0.userID.id.isEmpty }.map { DynamiteMapper.person($0) }
    }
    /// The organisation's enabled emoji matching `query` (what follows ":"), as Google Chat's web searches them: up to 40.
    public func searchCustomEmoji(matching query: String) async throws -> [CustomEmoji] {
        let request = Dynamite_SearchEmojisRequest.with { request in
            request.query = ":" + query
            request.types = [.custom]
            request.limit = 40
        }
        let response: Dynamite_SearchEmojisResponse = try await rpc("search_emojis_v2", request)
        return response.results.compactMap { result in
            guard case .customEmoji(let proto) = result.emoji, proto.state == .enabled else { return nil }
            return DynamiteMapper.customEmoji(proto)
        }
    }
    static let customEmojiFilters: [Dynamite_ListCustomEmojisRequest.Filter] = [
        .with {
            $0.kind = 2
            $0.states.states = [.enabled, .systemDisabled]
            $0.operation = 1
        },
        .with {
            $0.kind = 3
            $0.states.states = [.enabled]
            $0.operation = 1
        },
    ]
}
