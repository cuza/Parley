import Foundation
import ParleyDomain

/// The messages loaded, and the bookkeeping of their pages: which timelines are loaded, loading or have older pages,
/// detached windows of old history, shortcut lists and their cursors, the Threads lists, and the message highlighted.
/// `ChatStore`'s actions fetch the pages through the backend; this model holds them and the rules that need nothing else.
@MainActor @Observable final class TimelineModel {
    var messages: [Message] = [] { didSet { timelines = [:] } }
    /// Sorted timelines by draft key, kept until `messages` changes: a timeline view reads its messages several times
    /// per update, and filtering and sorting every loaded message each time showed up in profiles.
    @ObservationIgnored var timelines: [String: [Message]] = [:]
    @ObservationIgnored var loaded: Set<String> = []  // draft keys whose newest page came this session
    /// Draft keys with a page on its way: a timeline's (`pageLoads`) or a shortcut's, which has no task to wait for.
    var loading: Set<String> = []
    @ObservationIgnored var pageLoads: [String: Task<Void, Never>] = [:]
    var hasMore: Set<String> = []  // draft keys with older pages on the server
    /// Conversations showing a window of their history away from the newest messages (`ChatStore.open(_:at:)`), until
    /// paging down meets them.
    var detached: Set<ConversationID> = []
    /// A detached window's newest message.
    var windowEnds: [ConversationID: Date] = [:] { didSet { timelines = [:] } }
    @ObservationIgnored var newerLoads: Set<ConversationID> = []
    var shortcutLists: [Shortcut: [Message]] = [:]
    @ObservationIgnored var shortcutCursors: [Shortcut: String] = [:]
    var threadSummaries: [ConversationID: [ThreadSummary]] = [:]
    /// A message just jumped to, outlined in the timeline; it fades after `highlightDuration`, as Telegram flashes it.
    var highlightedID: MessageID? {
        didSet {
            highlightFade?.cancel()
            guard highlightedID != nil else { return }
            highlightFade = Task { [weak self, highlightDuration] in
                try? await Task.sleep(for: highlightDuration)
                guard !Task.isCancelled else { return }
                self?.highlightedID = nil
            }
        }
    }
    @ObservationIgnored var highlightDuration: Duration
    @ObservationIgnored private var highlightFade: Task<Void, Never>?
    /// Voice messages whose whole transcript shows; the rest show one line, as Google Chat does.
    var openTranscripts: Set<MessageID> = []

    init(highlightDuration: Duration = .seconds(3)) { self.highlightDuration = highlightDuration }

    /// `scope`'s messages oldest first. A detached window ends at its newest loaded page: messages arriving live wait below
    /// it until paging down reaches them.
    func timeline(_ conversation: ConversationID, thread: ThreadID?, scope: String) -> [Message] {
        let all = messages  // read on every call, so a view showing it still updates when messages change
        let end = thread == nil ? windowEnds[conversation] : nil
        if let cached = timelines[scope] { return cached }
        let sorted = all.filter { message in
            message.conversationID == conversation && message.threadID == thread
                && end.map { message.createdAt <= $0 } ?? true
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        timelines[scope] = sorted
        return sorted
    }
    /// Adds `message`, or replaces the copy held.
    func put(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }
    /// The sent messages a scope shows now: what a page that replaces it may drop.
    func shownSent(_ conversation: ConversationID, thread: ThreadID?) -> Set<MessageID> {
        Set(
            messages.lazy.filter { $0.conversationID == conversation && $0.threadID == thread && $0.delivery == .sent }
                .map(\.id))
    }
    /// A page came for `scope`: it is loaded, and has older pages when the server says so.
    func landed(_ scope: String, hasMore more: Bool) {
        loaded.insert(scope)
        if more { hasMore.insert(scope) } else { hasMore.remove(scope) }
    }
    /// A page in a detached window moves its end; one that reaches the newest messages ends the window.
    func extendWindow(_ conversation: ConversationID, _ page: MessagePage) {
        if page.hasNewer {
            detached.insert(conversation)
            if let newest = page.messages.map(\.createdAt).max() {
                windowEnds[conversation] = max(windowEnds[conversation] ?? newest, newest)
            }
        } else {
            attach(conversation)
        }
    }
    /// The conversation's timeline shows its newest messages again.
    func attach(_ conversation: ConversationID) {
        detached.remove(conversation)
        windowEnds[conversation] = nil
    }
    func toggleTranscript(_ id: MessageID) { if openTranscripts.remove(id) == nil { openTranscripts.insert(id) } }
    /// Stops the page loads and the highlight's fade, before the model is dropped.
    func cancel() {
        pageLoads.values.forEach { $0.cancel() }
        highlightFade?.cancel()
    }
}
