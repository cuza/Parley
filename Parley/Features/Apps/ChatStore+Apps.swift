import Foundation
import ParleyDomain

extension ChatStore {
    /// A picked "/" entry that runs at once: Google Chat's "Send a Meet link" (sent, then opened), or an app's quick
    /// command (its dialog, for the conversation).
    func run(_ command: SlashCommand, in conversation: ConversationID) async {
        switch command.action {
        case .meetLink: if let url = await sendMeetLink(in: conversation) { openURL(url) }
        case .quick:
            await openDialog(
                DialogContext(command: command.id, in: conversation, app: command.appID), app: command.appName,
                in: conversation, action: nil, inputs: [])
        case nil: break
        }
    }
    /// A card button's action (a Drive comment's Reply, Resolve, a poll's Vote): sent with the card's id and inputs; the
    /// app's answer replaces the message. A refusal says why, naming the app as Google Chat does. A button that opens the
    /// app's dialog opens it (`openDialog`).
    func clickCard(_ message: Message, card: String?, action: Data, inputs: [Card.Input]) async {
        let cards = message.attachments.compactMap(\.card)
        if let owner = cards.first(where: { $0.links.contains { $0.action == action && $0.dialog == true } }) {
            let app = owner.app ?? message.sender.id
            await openDialog(
                DialogContext(message: message.id, app: app), app: owner.by?.name ?? message.sender.name,
                in: message.conversationID, action: action, inputs: inputs)
            return
        }
        do {
            if let updated = try await backend.clickCard(message.id, card: card, action: action, inputs: inputs) {
                upsert(updated)
                persist()
            }
        } catch DynamiteError.appRefused(let why) {
            self.error = "\(message.sender.name) is unable to process your request." + (why.isEmpty ? "" : " " + why)
        } catch {
            report(error)
        }
    }
    /// An app's dialog showing over its conversation, with what the app last said was wrong.
    struct OpenDialog: Hashable {
        var context: DialogContext
        var conversation: ConversationID
        var app: String  // its name, for the sheet's title when the card has none and for errors
        var dialog: AppDialog
        var problem: String?
    }
    /// Opens an app's dialog: from a card's button (its action and the card's inputs), or with no action for a slash
    /// command's message. A refusal shows as an error; the dialog shows in a sheet over `conversation`.
    func openDialog(
        _ context: DialogContext, app: String, in conversation: ConversationID, action: Data?, inputs: [Card.Input]
    ) async {
        do {
            let answer = try await backend.dialog(.open, context, action: action, inputs: inputs)
            if case .show(let shown) = answer {
                dialog = OpenDialog(context: context, conversation: conversation, app: app, dialog: shown)
            } else {
                apply(answer, app: app)
            }
        } catch { report(error) }
    }
    /// One of the open dialog's buttons: its action with every input. The app answers with the next step (same sheet),
    /// what's wrong (kept open, said in the sheet), or done (closed, with its note as a toast).
    func submitDialog(action: Data, inputs: [Card.Input]) async {
        guard let open = dialog else { return }
        do {
            let answer = try await backend.dialog(.submit, open.context, action: action, inputs: inputs)
            guard dialog?.context == open.context else { return }  // closed meanwhile
            apply(answer, app: open.app)
        } catch {
            guard dialog?.context == open.context else { return }
            dialog?.problem = error.localizedDescription
        }
    }
    /// Closes the dialog (✕, Escape) and tells the app, as Google Chat does, without waiting for its answer.
    func cancelDialog() async {
        guard let open = dialog else { return }
        dialog = nil
        _ = try? await backend.dialog(.cancel, open.context, action: nil, inputs: [])
    }
    private func apply(_ answer: DialogAnswer, app: String) {
        switch answer {
        case .show(let next):
            dialog?.dialog = next
            dialog?.problem = nil
        case .close(let note):
            dialog = nil
            if let note { toast = note }
        case .invalid(let why):
            let text = why.isEmpty ? "\(app) is unable to process your request." : why
            if dialog != nil { dialog?.problem = text } else { error = text }
        case .configure(let url):
            dialog = nil
            openURL(url)
        }
    }
    /// Hides a message's dismissible cards (an app suggestion's "Don't install"), in Parley only, for good.
    func dismissCard(of message: Message) {
        let dismissed = defaults.stringArray(forKey: Self.dismissedCardsKey) ?? []
        // ponytail: an ever-growing list of message ids; trim it if it ever gets long.
        if !dismissed.contains(message.id.rawValue) {
            defaults.set(dismissed + [message.id.rawValue], forKey: Self.dismissedCardsKey)
        }
        if let current = history.messages.first(where: { $0.id == message.id }) {
            upsert(current)
            persist()
        }  // the launch cache too
    }
    /// Asks the server for `conversation`'s commands matching what's typed after "/", as Google Chat does on each key
    /// (the full list comes a page at a time). A bare "/" starts over, so added or removed apps show; each other query
    /// is asked once and its commands join the list.
    func loadSlashCommands(_ conversation: ConversationID, query: String) async {
        guard lookups.startSlashQuery(query, in: conversation) else { return }
        do {
            let toApp = self.conversation(conversation)?.app != nil
            let found = try await backend.searchSlashCommands(in: conversation, matching: query, toApp: toApp)
            lookups.addSlashCommands(found, for: query, in: conversation)
        } catch {
            lookups.slashQueries[conversation]?.remove(query)
            if (error as? AuthFailure)?.endsSession == true { report(error) }
        }
    }
}
