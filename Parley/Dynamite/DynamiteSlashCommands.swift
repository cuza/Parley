import Foundation

/// Slash commands as Google Chat lists them (`search_integration_actions`) and sends them (an annotation over the name).
extension DynamiteMapper {
    /// The request web's composer sends as a "/command" is typed: every app's commands (filter 2) in a space (surface 3)
    /// or a person's DM (surface 1); an app's DM asks for that app's only (filter 1, surface 2).
    static func slashCommandSearch(_ query: String, in group: Dynamite_GroupId, toApp: Bool = false) -> Dynamite_SearchIntegrationActionsRequest {
        .with { r in
            r.query = query
            r.groupID = group
            r.pageSize = 25
            r.kinds = [toApp ? 1 : 2]
            r.flag5 = true
            r.surface = toApp ? 2 : group.hasDmID ? 1 : 3
            r.limit.value = 5
            r.features.values = [8]
            r.requestHeader = DynamiteClient.header
        }
    }
    /// The listed commands, in the server's order, each once: slash and quick commands of the conversation's apps, and
    /// Google Chat's "Send a Meet link". Apps not in the conversation, message actions and Google's other actions
    /// (Drive, Calendar, Docs…) are left out: Parley offers only what the conversation itself has.
    static func slashCommands(_ response: Dynamite_SearchIntegrationActionsResponse) -> [SlashCommand] {
        var seen = Set<String>()
        return response.actions.compactMap { action -> SlashCommand? in
            if action.hasBuiltin {
                guard action.builtin.kind == 6, seen.insert("meet").inserted else { return nil }
                return SlashCommand(appID: "", appName: "Google Meet", name: "", id: 0, description: "Send a new meeting link",
                                    action: .meetLink, title: action.builtin.label.isEmpty ? "Send a Meet link" : action.builtin.label)
            }
            let item = action.appCommand, command = item.command
            let quick = command.kind.kind == 1 && !command.displayName.isEmpty
            guard item.installed, quick || (command.name.hasPrefix("/") && command.kind.kind != 1), !item.app.userID.id.isEmpty,
                  seen.insert("\(item.app.userID.id):\(command.id)").inserted else { return nil }
            return SlashCommand(appID: item.app.userID.id, appName: item.app.name, appAvatar: imageURL(item.app.avatarURL),
                                name: quick ? "" : command.name, id: command.id, description: command.description_p,
                                opensDialog: command.opensDialog, action: quick ? .quick : nil, title: quick ? command.displayName : nil)
        }
    }
    /// The annotation over a picked command's name at the start of the text, as Google Chat's composer sends it.
    static func slashCommand(_ range: TextStyleRange) -> Dynamite_Annotation? {
        guard case .slashCommand(let command) = range.style, range.start == 0, range.length > 0 else { return nil }
        return .with { a in
            a.type = .slashCommand; a.startIndex = 0; a.length = Int32(range.length)
            a.slashCommandMetadata = .with { m in
                m.appID.id = command.appID; m.appID.type = .bot
                m.type = 2   // invoke (1 would add the app first)
                m.name = command.name
                m.commandID = command.id
                m.argumentsHint = ""
                m.opensDialog = command.opensDialog
                m.description_p = command.description
                m.appName = command.appName
                m.appAvatarURL = command.appAvatar?.absoluteString ?? ""
                m.hidden = false
            }
        }
    }
}
