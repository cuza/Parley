import Foundation

/// An app's slash command, as the composer's "/" list offers it and a message invoking it carries it.
public struct SlashCommand: Hashable, Codable, Sendable {
    public var appID: PersonID
    public var appName: String
    public var appAvatar: URL?
    public var name: String  // "/help"
    public var id: Int64
    public var description = ""
    /// The app answers with a dialog: after the command's message is sent, the dialog is asked for (`invoke_dialog`).
    public var opensDialog = false
    /// Not a "/name" to send but run as soon as it's picked: an app's quick command (its dialog) or Google Chat's own action.
    public var action: Action?
    public enum Action: String, Codable, Sendable { case quick, meetLink }
    public var title: String?  // what a nameless one is listed as ("Create a poll")
    public var label: String { title ?? name }
    public init(
        appID: PersonID, appName: String, appAvatar: URL? = nil, name: String, id: Int64, description: String = "",
        opensDialog: Bool = false,
        action: Action? = nil, title: String? = nil
    ) {
        self.appID = appID
        self.appName = appName
        self.appAvatar = appAvatar
        self.name = name
        self.id = id
        self.description = description
        self.opensDialog = opensDialog
        self.action = action
        self.title = title
    }

    /// Commands whose name (without "/"), title or app's name contains `query`, ignoring case, as the server matches
    /// them; names starting with it first, then other name matches, then by name.
    public static func filter(_ commands: [SlashCommand], by query: String, limit: Int = 8) -> [SlashCommand] {
        let query = query.lowercased()
        func key(_ command: SlashCommand) -> String { (command.title ?? String(command.name.dropFirst())).lowercased() }
        func rank(_ command: SlashCommand) -> (Int, String) {
            let name = key(command)
            return (name.hasPrefix(query) ? 0 : name.contains(query) ? 1 : 2, name)
        }
        return Array(
            commands.filter { query.isEmpty || key($0).contains(query) || $0.appName.lowercased().contains(query) }
                .sorted { rank($0) < rank($1) }.prefix(limit))
    }
}
