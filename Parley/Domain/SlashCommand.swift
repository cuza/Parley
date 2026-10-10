import Foundation

/// An app's slash command, as the composer's "/" list offers it and a message invoking it carries it.
struct SlashCommand: Hashable, Codable, Sendable {
    var appID: String
    var appName: String
    var appAvatar: URL? = nil
    var name: String            // "/help"
    var id: Int64
    var description = ""
    /// The app answers with a dialog: after the command's message is sent, the dialog is asked for (`invoke_dialog`).
    var opensDialog = false
    /// Not a "/name" to send but run as soon as it's picked: an app's quick command (its dialog) or Google Chat's own action.
    var action: Action? = nil
    enum Action: String, Codable, Sendable { case quick, meetLink }
    var title: String? = nil    // what a nameless one is listed as ("Create a poll")
    var label: String { title ?? name }

    /// Commands whose name (without "/"), title or app's name contains `query`, ignoring case, as the server matches
    /// them; names starting with it first, then other name matches, then by name.
    static func filter(_ commands: [SlashCommand], by query: String, limit: Int = 8) -> [SlashCommand] {
        let query = query.lowercased()
        func key(_ command: SlashCommand) -> String { (command.title ?? String(command.name.dropFirst())).lowercased() }
        func rank(_ command: SlashCommand) -> (Int, String) {
            let name = key(command)
            return (name.hasPrefix(query) ? 0 : name.contains(query) ? 1 : 2, name)
        }
        return Array(commands.filter { query.isEmpty || key($0).contains(query) || $0.appName.lowercased().contains(query) }
            .sorted { rank($0) < rank($1) }.prefix(limit))
    }
}

extension MentionQuery {
    /// The "/command" being typed: a "/" at the very start of the message, then no whitespace up to the caret.
    static func slash(in string: String, caret: Int) -> MentionQuery? {
        let ns = string as NSString
        guard caret >= 1, caret <= ns.length, ns.character(at: 0) == 47 else { return nil }   // "/"
        let text = ns.substring(with: NSRange(location: 1, length: caret - 1))
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return MentionQuery(range: NSRange(location: 0, length: caret), text: text, command: true)
    }
}
