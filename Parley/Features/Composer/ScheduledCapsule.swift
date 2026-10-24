import ParleyDomain
import SwiftUI

/// Over the composer: when its next scheduled message goes, and how many more wait; a click opens Drafts.
struct ScheduledCapsule: View {
    @Environment(ChatStore.self) private var store
    let conversation: Conversation
    var thread: ThreadID?
    var body: some View {
        if let next = store.drafting.scheduled(in: conversation.id, thread: thread).first,
            let at = next.schedule?.at
        {  // as web says it
            let more = store.drafting.scheduled(in: conversation.id, thread: thread).count - 1
            Button {
                Task { await store.openShortcut(.drafts) }
            } label: {
                Label(
                    more > 0
                        ? "Scheduled for \(ScheduledSend.when(at, inSentence: true)), and \(more) more"
                        : "Scheduled for \(ScheduledSend.when(at, inSentence: true))",
                    systemImage: "clock"
                ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.buttonStyle(.plain).help("See scheduled messages").floatingCapsule()
        }
    }
}
