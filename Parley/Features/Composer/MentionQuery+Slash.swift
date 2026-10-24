import Foundation

extension MentionQuery {
    /// The "/command" being typed: a "/" at the very start of the message, then no whitespace up to the caret.
    static func slash(in string: String, caret: Int) -> MentionQuery? {
        let ns = string as NSString
        guard caret >= 1, caret <= ns.length, ns.character(at: 0) == 47 else { return nil }  // "/"
        let text = ns.substring(with: NSRange(location: 1, length: caret - 1))
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return MentionQuery(range: NSRange(location: 0, length: caret), text: text, command: true)
    }
}
