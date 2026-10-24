/// Waits for a pause in typing before a search, so a search runs per pause and not per keystroke. Call it at the top of
/// a `.task(id:)` keyed on the query: a new keystroke cancels the task and the wait.
enum TypingPause {
    /// False when another keystroke came first.
    static func ended() async -> Bool {
        try? await Task.sleep(for: .milliseconds(250))
        return !Task.isCancelled
    }
}
