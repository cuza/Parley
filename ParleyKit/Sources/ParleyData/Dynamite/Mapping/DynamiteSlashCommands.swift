import Foundation
import ParleyDomain

/// Slash commands as Google Chat lists them (`search_integration_actions`) and sends them (an annotation over the name).
extension DynamiteMapper {
    /// The request web's composer sends as a "/command" is typed: every app's commands (filter 2) in a space (surface 3)
    /// or a person's DM (surface 1); an app's DM asks for that app's only (filter 1, surface 2).
    static func slashCommandSearch(_ query: String, in group: Dynamite_GroupId, toApp: Bool = false)
        -> Dynamite_SearchIntegrationActionsRequest
    {
        .with { request in
            request.query = query
            request.groupID = group
            request.pageSize = 25
            request.kinds = [toApp ? 1 : 2]
            request.flag5 = true
            request.surface = toApp ? 2 : group.hasDmID ? 1 : 3
            request.limit.value = 5
            request.features.values = [8]
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
                return SlashCommand(
                    appID: "", appName: "Google Meet", name: "", id: 0, description: "Send a new meeting link",
                    action: .meetLink, title: action.builtin.label.isEmpty ? "Send a Meet link" : action.builtin.label)
            }
            let item = action.appCommand
            let command = item.command
            let quick = command.kind.kind == 1 && !command.displayName.isEmpty
            guard item.installed, quick || (command.name.hasPrefix("/") && command.kind.kind != 1),
                !item.app.userID.id.isEmpty,
                seen.insert("\(item.app.userID.id):\(command.id)").inserted
            else { return nil }
            return SlashCommand(
                appID: PersonID(item.app.userID.id), appName: item.app.name, appAvatar: imageURL(item.app.avatarURL),
                name: quick ? "" : command.name, id: command.id, description: command.description_p,
                opensDialog: command.opensDialog, action: quick ? .quick : nil, title: quick ? command.displayName : nil
            )
        }
    }
    /// The annotation over a picked command's name at the start of the text, as Google Chat's composer sends it.
    static func slashCommand(_ range: TextStyleRange) -> Dynamite_Annotation? {
        guard case .slashCommand(let command) = range.style, range.start == 0, range.length > 0 else { return nil }
        return .with { annotation in
            annotation.type = .slashCommand
            annotation.startIndex = 0
            annotation.length = Int32(range.length)
            annotation.slashCommandMetadata = .with { metadata in
                metadata.appID.id = command.appID.rawValue
                metadata.appID.type = .bot
                metadata.type = 2  // invoke (1 would add the app first)
                metadata.name = command.name
                metadata.commandID = command.id
                metadata.argumentsHint = ""
                metadata.opensDialog = command.opensDialog
                metadata.description_p = command.description
                metadata.appName = command.appName
                metadata.appAvatarURL = command.appAvatar?.absoluteString ?? ""
                metadata.hidden = false
            }
        }
    }
}
