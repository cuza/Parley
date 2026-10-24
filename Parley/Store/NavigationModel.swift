import Foundation
import ParleyDomain

/// Where the user is: the conversation or shortcut the main window shows, every window's side pane, and the places Back
/// and Forward go to. `ChatStore`'s actions load what a place shows; this model holds the place.
@MainActor @Observable final class NavigationModel {
    /// An Ask Gemini session fills the page, so it is a place of its own; another conversation's thread is a side pane.
    enum Place: Hashable {
        case conversation(ConversationID)
        case shortcut(Shortcut)
        case session(ConversationID, ThreadID)
        var conversation: ConversationID? {
            switch self {
            case .conversation(let id), .session(let id, _): id
            case .shortcut: nil
            }
        }
    }

    var selectedID: ConversationID? { didSet { if selectedID != oldValue { left() } } }
    /// The sidebar shortcut shown instead of a conversation; nil while a conversation shows.
    var shortcut: Shortcut? { didSet { if shortcut != oldValue { left() } } }
    /// Each window's side pane, by the conversation a conversation window shows; nil is the main window's.
    private(set) var panes: [ConversationID?: SidePane] = [:]
    var backPlaces: [Place] = []
    var forwardPlaces: [Place] = []
    /// The conversations open in a window of their own.
    private(set) var ownWindows: Set<ConversationID> = []
    /// Called when the main window's conversation, shortcut or thread changes: leaving a composer saves its draft.
    @ObservationIgnored var left: @MainActor () -> Void = {}

    /// The thread open in the main window's side pane, also under a person's details.
    var threadID: ThreadID? { pane(nil).thread }
    func pane(_ window: ConversationID?) -> SidePane { panes[window] ?? SidePane() }
    func setPane(_ window: ConversationID?, _ change: (inout SidePane) -> Void) {
        let old = pane(window)
        var pane = old
        change(&pane)
        guard pane != old else { return }
        panes[window] = pane
        if window == nil, pane.thread != old.thread { left() }
    }
    func windowOpened(_ conversation: ConversationID) { ownWindows.insert(conversation) }
    func windowClosed(_ conversation: ConversationID) { ownWindows.remove(conversation) }
    /// The window that shows `conversation`, by the same key as `panes`: its own window while one is open, else the main
    /// window (nil).
    func window(for conversation: ConversationID) -> ConversationID? {
        ownWindows.contains(conversation) ? conversation : nil
    }
    var canGoForward: Bool { !forwardPlaces.isEmpty }
    /// Opening a new place: the current one goes on the back list and the forward list ends, as in a browser.
    func visit(_ next: Place, from current: Place?) {
        guard let current, current != next else { return }
        backPlaces.append(current)
        forwardPlaces = []
        if backPlaces.count > 100 { backPlaces.removeFirst() }
    }
    /// The place Back goes to, with `current` kept for Forward; nil when there is none.
    func back(from current: Place?) -> Place? {
        guard let place = backPlaces.popLast() else { return nil }
        if let current { forwardPlaces.append(current) }
        return place
    }
    func forward(from current: Place?) -> Place? {
        guard let place = forwardPlaces.popLast() else { return nil }
        if let current { backPlaces.append(current) }
        return place
    }
    /// A conversation that is gone is no place to go back or forward to.
    func forget(_ conversation: ConversationID) {
        backPlaces.removeAll { $0.conversation == conversation }
        forwardPlaces.removeAll { $0.conversation == conversation }
    }
}
