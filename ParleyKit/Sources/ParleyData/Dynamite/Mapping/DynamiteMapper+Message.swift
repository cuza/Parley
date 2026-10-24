import Foundation
import ParleyDomain
import os

extension DynamiteMapper {
    static func message(
        _ proto: Dynamite_Message, in conversation: ConversationID, selfID: String, people: [String: Person]
    ) -> Message? {
        guard !proto.id.messageID.isEmpty else { return nil }
        let senderID = proto.creator.userID.id
        let sender = people[senderID] ?? person(proto.creator)
        let id = DynamiteID.message(conversation, topic: proto.id.parentID.topicID.topicID, message: proto.id.messageID)
        let missing = MessageCoverage.gaps(proto, selfID: selfID)
        // Anonymous: the fields only, once per shape; the shape is kept for Settings ▸ Advanced ▸ Export.
        if !missing.isEmpty, MessageShapes.shared.withLock({ $0.record(proto, fields: missing) }) {
            log.notice("\(MessageShapes.logLine(missing), privacy: .public)")
        }
        // A deleted message Google Chat keeps in its place: who deleted it, in italics, as Google Chat shows it.
        if proto.tombstone.isTombstone {
            return tombstone(proto, id: id, in: conversation, sender: sender)
        }
        guard proto.deleteTime == 0 else { return nil }
        // A system event becomes a service line when we can say what happened; the rest are hidden, as web shows no bubble.
        if isSystem(proto) {
            guard let line = systemText(proto, in: conversation, selfID: selfID, people: people) else { return nil }
            return Message(
                id: id, conversationID: conversation, sender: sender, text: line, createdAt: date(proto.createTime),
                isSystem: true)
        }
        let reactions = proto.reactions.compactMap {
            reaction($0.emoji, count: Int($0.count), mine: $0.currentUserReacted, selfID: selfID)
        }
        let attachments = messageAttachments(proto, id: id, people: people)
        let (quote, fallback) = quotedMessage(proto, in: conversation, people: people)
        let rich = richText(proto.textBody, proto.annotations, hiding: fallback)
        if rich.text.isEmpty, attachments.isEmpty,
            let failure = appFailure(proto, id: id, in: conversation, sender: sender)
        {
            return failure
        }
        // Nothing Parley can draw yet: say so and link to it in Google Chat rather than show an empty bubble.
        let unsupported = rich.text.isEmpty && attachments.isEmpty
        let open = ChatLink.url(message: id).map { Attachment(name: "Open in Google Chat", kind: .link, url: $0) }
        var message = Message(
            id: id, conversationID: conversation, sender: sender,
            text: unsupported ? "Unsupported message" : rich.text,
            // Google updates a Meet call's message as the call ends: not an edit anyone made.
            createdAt: date(proto.createTime), edited: proto.lastEditTime > 0 && !isMeetCall(proto),
            reactions: reactions, attachments: unsupported ? open.map { [$0] } ?? [] : attachments,
            formatting: rich.formatting, quote: quote,
            lastUpdateMicros: [proto.lastUpdateTime, proto.lastEditTime, proto.createTime].first { $0 > 0 },
            via: via(proto, people: people),
            starred: proto.messageLabels.contains { $0.type == .star })
        // Google Chat gives a picture a new token, so a new URL, on every load: its cache knows it by its message and place.
        for index in message.attachments.indices { message.attachments[index].cacheKey = "\(id)#\(index)" }
        message.sources = sources(proto.annotations)
        message.pinned = proto.messageLabels.contains { $0.type == .pinned }
        message.thinking = thinking(proto.annotations)
        message.translation = translation(proto)
        return message
    }
    /// A deleted message's placeholder, worded for who deleted it, in italics.
    private static func tombstone(
        _ proto: Dynamite_Message, id: MessageID, in conversation: ConversationID, sender: Person
    ) -> Message {
        let text =
            switch proto.tombstoneMetadata.type {
            case 2, 6: "Message deleted by a space manager"
            case 3: "Message deleted by an admin"
            case 4: "Message expired"
            default: "Message deleted"
            }
        return Message(
            id: id, conversationID: conversation, sender: sender, text: text, createdAt: date(proto.createTime),
            formatting: [TextStyleRange(style: .italic, start: 0, length: (text as NSString).length)],
            tombstone: true)
    }
    /// The message's chips, calls and cards, in the order they show.
    private static func messageAttachments(_ proto: Dynamite_Message, id: MessageID, people: [String: Person])
        -> [Attachment]
    {
        let cards = cards(proto, id: id, people: people)
        // A card shows the file the notice names: no second chip for it, as Google Chat shows none.
        let chips = proto.annotations.compactMap(attachment).filter {
            cards.isEmpty || !($0.kind == .link && $0.domain == nil)
        }
        return chips + proto.annotations.compactMap(call) + cards + appCards(proto, id: id, people: people)
    }
    /// The message a quote reply or a forward names, and the range of a fallback line in the text to hide.
    private static func quotedMessage(
        _ proto: Dynamite_Message, in conversation: ConversationID, people: [String: Person]
    ) -> (QuotedMessage?, NSRange?) {
        guard proto.hasQuotedMessageMetadata else { return (nil, nil) }
        let quoted = proto.quotedMessageMetadata
        let id = quoted.creator.userID.id
        let quotedText = richText(quoted.textBody, quoted.annotations)
        // A forward names the conversation it came from, where its id lives; a DM has no name.
        let forwarded = quoted.quoteType == .forward
        let source = forwarded ? DynamiteID.conversation(quoted.group.groupID) ?? conversation : conversation
        // ponytail: quoted authors are not looked up; the name comes from people already resolved or the snapshot. Resolve them if "Unknown" shows up.
        let plain = TextStyleRange.plainWithEmoji(quotedText.text, quotedText.formatting)
        let quote = QuotedMessage(
            sender: people[id]?.name ?? (quoted.creator.name.isEmpty ? "Unknown" : quoted.creator.name),
            text: QuotedMessage.summary(text: plain.text, attachments: quoted.annotations.compactMap(attachment)),
            id: quoted.messageID.messageID.isEmpty
                ? nil
                : DynamiteID.message(
                    source, topic: quoted.messageID.parentID.topicID.topicID, message: quoted.messageID.messageID),
            forwardedFrom: forwarded ? (quoted.group.name.isEmpty ? "a direct message" : quoted.group.name) : nil,
            emoji: plain.emoji.isEmpty || plain.text.isEmpty ? nil : plain.emoji)
        // UNVERIFIED: the server may also write a "↪ _Name: …_" line for clients without field 37.
        let fallback =
            proto.textBody.hasPrefix("↪")
            ? (proto.textBody as NSString).lineRange(for: NSRange(location: 0, length: 0)) : nil
        return (quote, fallback)
    }
    /// An app that couldn't answer sends no text, only why: say so, with a link to set it up when it needs that.
    private static func appFailure(
        _ proto: Dynamite_Message, id: MessageID, in conversation: ConversationID, sender: Person
    ) -> Message? {
        guard
            let response = proto.botResponses.first(where: { $0.type != appSuggestion && $0.type != slashCommandEcho })
        else { return nil }
        let app = response.bot.name.isEmpty ? sender.name : response.bot.name
        let setup = URL(string: response.setupURL).flatMap {
            $0.scheme == "https" ? Attachment(name: "Configure \(app)", kind: .link, url: $0) : nil
        }
        return Message(
            id: id, conversationID: conversation, sender: sender, text: "\(app) couldn’t respond",
            createdAt: date(proto.createTime),
            attachments: setup.map { [$0] } ?? [])
    }
    /// "App" after an app's name, the app that posted for a person, and "Only visible to you" on a message only I can
    /// see (one for named viewers, or one the server holds for me alone: message state 2).
    private static func via(_ proto: Dynamite_Message, people: [String: Person]) -> String? {
        [
            proto.creator.userID.type == .bot ? "App" : nil, appIDs(proto).first.map { people[$0]?.name ?? "App" },
            proto.privateMessageViewers.isEmpty && proto.messageState != 2 ? nil : "Only visible to you",
        ]
        .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
    /// "Show thinking": the last activity annotation with steps, as Google Chat shows it.
    private static func thinking(_ annotations: [Dynamite_Annotation]) -> [ThinkingStep] {
        annotations.reversed().lazy.compactMap { annotation -> [ThinkingStep]? in
            guard case .activityMetadata(let activity)? = annotation.metadata, !activity.log.entries.isEmpty else {
                return nil
            }
            return activity.log.entries.map { ThinkingStep(title: $0.title, text: $0.content) }
        }.first ?? []
    }
    /// Google's translation for me, with its own formatting; shown first, the original a click away.
    private static func translation(_ proto: Dynamite_Message) -> Translation? {
        guard proto.hasTranslation, !proto.translation.text.isEmpty else { return nil }
        let translated = richText(proto.translation.text, proto.translation.annotations)
        return Translation(
            text: translated.text, formatting: translated.formatting, from: proto.translation.sourceLanguage)
    }
    /// A Gemini answer's sources, as Google Chat lists them under "N Sources": those of its zero-length citations, in
    /// order; without any, those its ranged citations name, each once.
    static func sources(_ annotations: [Dynamite_Annotation]) -> [Source] {
        let citations: [(length: Int32, sources: [Dynamite_ContextSource])] = annotations.compactMap { annotation in
            guard case .contextSourceMetadata(let metadata)? = annotation.metadata else { return nil }
            return (annotation.length, metadata.sources)
        }
        // The listed sources are kept as they come, even when two share a link (messages in one space can); only the
        // ranged citations, which repeat sources, are counted once.
        let listed = citations.filter { $0.length == 0 }
        var seen = Set<String>()
        let all: [Dynamite_ContextSource] =
            listed.isEmpty
            ? citations.flatMap(\.sources).filter { seen.insert($0.url).inserted } : listed.flatMap(\.sources)
        return all.compactMap { source -> Source? in
            // Some chat sources come over http: kept, and opened over https.
            guard var url = URL(string: source.url), url.scheme == "https" || url.scheme == "http" else { return nil }
            if url.scheme == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.scheme = "https"
                url = parts.url ?? url
            }
            let kind: Source.Kind =
                switch source.kind {
                case .gmail: .gmail
                case .calendar: .calendar
                case .docs: .docs
                case .sheets: .sheets
                case .slides: .slides
                case .drive, .pdf, .video, .audio, .image: .drive
                case .youtube: .youtube
                case .chat: .chat
                case .tasks: .tasks
                default: .web
                }
            let detail = [source.snippet.text, source.footer.text].first { !$0.isEmpty }
            return Source(
                title: source.title.isEmpty ? url.host() ?? source.url : source.title, url: url, kind: kind,
                detail: detail)
        }
    }
    static let appSuggestion: Int32 = 6  // BotResponse type APP_SUGGESTION
    /// BotResponse type on a slash command's own message: the command went to the app; nothing to draw.
    static let slashCommandEcho: Int32 = 5
    private static let log = Logger(subsystem: "dev.cuza.Parley", category: "dynamite")

    /// Annotation kinds that only system events carry.
    private static let systemKinds: Set<Dynamite_Annotation.TypeEnum> = [
        .membershipChanged, .roomUpdated, .groupRetentionSettingsUpdated, .readReceiptsSettingsUpdated,
        .incomingWebhookChanged, .integrationConfigUpdated, .migratedFromLegacyThreadedRoom,
    ]
    /// Marked SYSTEM_MESSAGE, carrying a system annotation, or no text with only metadata (membership, history setting, ...).
    static func isSystem(_ proto: Dynamite_Message) -> Bool {
        proto.messageType == .systemMessage
            || proto.annotations.contains { annotation in
                switch annotation.metadata {
                case .membershipChanged, .roomUpdated: true
                default: systemKinds.contains(annotation.type)
                }
            }
            || (proto.textBody.isEmpty && !proto.annotations.isEmpty && proto.annotations.compactMap(attachment).isEmpty
                && proto.annotations.compactMap(call).isEmpty && cards(proto).isEmpty
                && proto.appAttachments.isEmpty && !proto.annotations.contains { contentKinds.contains($0.type) })
    }
    /// Annotations that are a message's content (a file, a link, a chip…): a message carrying one is never taken for an
    /// empty system event and hidden, even when Parley can't draw it yet.
    private static let contentKinds: Set<Dynamite_Annotation.TypeEnum> = [
        .url, .driveFile, .driveDoc, .driveSheet, .driveSlide, .video, .image, .pdf, .videoCall, .uploadMetadata,
        .gsuiteIntegration, .driveForm, .customEmoji, .consentedAppUnfurl, .group, .email, .contextSource, .notebooklm,
        .meetingCard,
    ]
    /// Everyone a message names: its sender and, in a system event, who acted and who was affected (to look up names).
    static func userIDs(_ proto: Dynamite_Message) -> [String] {
        [proto.creator.userID.id]
            + proto.annotations.flatMap { annotation -> [String] in
                switch annotation.metadata {
                case .membershipChanged(let change): [change.initiator.id] + change.affectedMembers.map(\.userID.id)
                case .roomUpdated(let update): [update.initiator.userID.id]
                default: []
                }
            }
    }
    /// The service line for a system event, one line per change it describes; nil when it describes none.
    static func systemText(
        _ proto: Dynamite_Message, in conversation: ConversationID, selfID: String, people: [String: Person]
    ) -> String? {
        let noun = conversation.rawValue.hasPrefix("space/") ? "space" : "conversation"
        func name(_ id: String, _ snapshot: String = "", first: Bool) -> String {
            if id == selfID { return first ? "You" : "you" }
            return people[id]?.name ?? (snapshot.isEmpty ? (first ? "Someone" : "someone") : snapshot)
        }
        let lines = proto.annotations.compactMap { annotation -> String? in
            switch annotation.metadata {
            case .membershipChanged(let change):
                let snapshots = Dictionary(
                    change.affectedMemberProfiles.map { ($0.user.userID.id, $0.user.name) },
                    uniquingKeysWith: { first, _ in first })
                let ids = change.affectedMembers.map(\.userID.id).filter { !$0.isEmpty }
                func affected(first: Bool) -> String? {
                    ids.isEmpty
                        ? nil
                        : ListFormatter.localizedString(
                            byJoining: ids.enumerated().map { name($1, snapshots[$1] ?? "", first: first && $0 == 0) })
                }
                // An admin is not named, as for a room update.
                let actor =
                    change.initiatorType == 2
                    ? "An admin"
                    : name(change.initiator.id.isEmpty ? proto.creator.userID.id : change.initiator.id, first: true)
                switch change.type {
                case .added, .botAdded: return affected(first: false).map { "\(actor) added \($0)" }
                case .invited: return affected(first: false).map { "\(actor) invited \($0)" }
                case .removed, .botRemoved: return affected(first: false).map { "\(actor) removed \($0)" }
                case .joined: return "\(affected(first: true) ?? actor) joined"
                case .left: return "\(affected(first: true) ?? actor) left"
                default: return nil
                }
            case .roomUpdated(let update):
                let actorID = update.initiator.userID.id.isEmpty ? proto.creator.userID.id : update.initiator.userID.id
                let actor = name(actorID, update.initiator.name, first: true)
                if !update.renameMetadata.newName.isEmpty {
                    return "\(actor) renamed the \(noun) to “\(update.renameMetadata.newName)”"
                }
                if update.boardUpdate.action == 1, update.boardUpdate.kind == 1 {
                    return "\(actor) pinned a message to the board"
                }
                guard update.hasGroupDetailsMetadata else { return nil }
                // As Google Chat words it: a new description is quoted, guidelines are only named; an admin is not named.
                let who = update.initiatorType == 2 ? "An admin" : actor
                let new = update.groupDetailsMetadata.newGroupDetails
                let prev = update.groupDetailsMetadata.prevGroupDetails
                var changes: [String] = []
                if new.description_p != prev.description_p {
                    changes.append(
                        new.description_p.isEmpty
                            ? "\(who) removed the \(noun) description"
                            : "\(who) updated the \(noun) description to:\n\(new.description_p)")
                }
                if new.guidelines != prev.guidelines {
                    changes.append("\(who) \(new.guidelines.isEmpty ? "removed" : "updated") the \(noun) guidelines")
                }
                return changes.isEmpty ? nil : changes.joined(separator: "\n")
            default: return nil
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A pushed BATCH_REACTIONS_UPDATED, applied onto the message's `existing` reactions: it names only the emoji that changed,
    /// each replacing its own reaction (gone at count 0); the others stay as they are.
    static func reactions(_ summaries: [Dynamite_ReactionSummary], onto existing: [Reaction] = [], selfID: String)
        -> [Reaction]
    {
        var reactions = existing
        for summary in summaries {
            guard let (text, custom) = reactionKey(summary.emoji) else { continue }
            let changed = reaction(
                summary.emoji, count: Int(summary.count), mine: summary.currentUserReacted,
                reactors: summary.reactors.map(\.id), selfID: selfID)
            if let index = reactions.firstIndex(where: { $0.emoji == text && $0.custom?.id == custom?.id }) {
                if let changed { reactions[index] = changed } else { reactions.remove(at: index) }
            } else if let changed {
                reactions.append(changed)
            }
        }
        return reactions
    }
    /// A reaction's emoji as Parley keys it: its text (`:shortcode:` for a custom emoji) and the custom emoji, if any.
    static func reactionKey(_ emoji: Dynamite_Emoji) -> (text: String, custom: CustomEmoji?)? {
        let custom = if case .customEmoji(let proto) = emoji.content { customEmoji(proto) } else { CustomEmoji?.none }
        let text = custom?.text ?? emoji.unicode
        return text.isEmpty ? nil : (text, custom)
    }
    // ponytail: Domain Reaction stores people; the wire gives a count, the own flag and (pushed) the reactors it lists.
    // Filler IDs keep the count. Use real reactors everywhere when reaction details are fetched.
    private static func reaction(
        _ emoji: Dynamite_Emoji, count: Int, mine: Bool, reactors: [String] = [], selfID: String
    ) -> Reaction? {
        guard let (text, custom) = reactionKey(emoji), count > 0 else { return nil }
        var people = Set(reactors.filter { !$0.isEmpty }.map { PersonID($0) })
        if mine { people.insert(PersonID(selfID)) }
        while people.count < count { people.insert(PersonID("reactor-\(people.count)")) }
        return Reaction(emoji: text, people: people, custom: custom)
    }

    /// A custom emoji as Google Chat sends it; the whole message is kept as `payload` for sending back.
    static func customEmoji(_ proto: Dynamite_CustomEmoji) -> CustomEmoji? {
        guard !proto.uuid.isEmpty || !proto.shortcode.isEmpty else { return nil }
        var image: URL?
        // Encoded strictly: URLComponents leaves "+" and "/" as they are, and a server reads "+" in a query as a space.
        if proto.state != .deleted,
            let token = proto.readToken.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))), !token.isEmpty
        {
            image = URL(
                string: "https://chat.google.com/api/get_custom_emoji_image?custom_emoji_read_token=\(token)&rwa=true")
        }
        let shortcode = proto.shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))  // stored with its colons or without
        return CustomEmoji(
            id: proto.uuid, shortcode: shortcode.isEmpty ? "emoji" : shortcode, imageURL: image,
            deleted: proto.state == .deleted, payload: (try? proto.serializedData()) ?? Data())
    }
    /// The `Emoji` a reaction request names: a custom emoji exactly as the server sent it, else the unicode text.
    static func emoji(_ text: String, custom: CustomEmoji?) -> Dynamite_Emoji {
        guard let custom else { return .with { $0.unicode = text } }
        let proto =
            (try? Dynamite_CustomEmoji(serializedBytes: custom.payload))
            ?? .with {
                $0.uuid = custom.id
                $0.shortcode = custom.shortcode
            }
        return .with { $0.customEmoji = proto }
    }

    /// The apps that made the message's cards, looked up as bots for the card's "By <app>" line.
    static func cardAppIDs(_ proto: Dynamite_Message) -> [String] {
        (proto.appAttachments.map(\.app.userID.id) + proto.botResponses.map(\.bot.userID.id)).filter { !$0.isEmpty }
    }
    /// The app that posted a message on its sender's behalf (a bot user id, looked up as a bot).
    static func appIDs(_ proto: Dynamite_Message) -> [String] {
        proto.creator.userID.actingUserID.isEmpty ? [] : [proto.creator.userID.actingUserID]
    }
    /// What a quote reply or a forward sends to name the message: its id and update time, as Google Chat sends it. nil without an id.
    static func quotedRef(_ quote: QuotedMessage) throws -> Dynamite_QuotedMessageRef? {
        guard let id = quote.id else { return nil }
        let messageID = try DynamiteID.protoMessageID(id)
        return .with {
            $0.messageID = messageID
            $0.lastUpdateTime = quote.lastUpdateMicros ?? 0
            $0.quoteType = quote.forwardedFrom == nil ? .quoteReply : .forward
        }
    }
}
