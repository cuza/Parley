import ParleyDomain
import SwiftUI

/// The Drafts shortcut, as web's: scheduled messages, soonest first, then every composer holding a draft, newest first; a
/// click opens the conversation, or the thread in the thread pane, with the draft in its composer.
struct DraftList: View {
    @Environment(ChatStore.self) private var store
    var body: some View {
        let drafts = store.draftList()
        let scheduled = store.drafting.scheduled
        Group {
            if drafts.isEmpty && scheduled.isEmpty {
                ContentUnavailableView(
                    "No drafts", systemImage: Shortcut.drafts.icon,
                    description: Text("Messages you start and don’t send show up here."))
            } else {
                List {  // one list, as web's: scheduled messages carry their send time
                    ForEach(scheduled, id: \.id) { ScheduledRow(message: $0) }
                    ForEach(drafts, id: \.self) { draft in
                        Button {
                            Task { await store.open(conversation: draft.conversationID, thread: draft.threadID) }
                        } label: {
                            row(draft)
                        }
                        .buttonStyle(.plain)
                        // Deleting a draft can't be undone: a tap on the swipe's button, never a full swipe.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await store.deleteDraft(draft) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Delete Draft", role: .destructive) { Task { await store.deleteDraft(draft) } }
                        }
                    }
                }
                .accessibilityIdentifier("shortcut-drafts")
            }
        }
        .navigationTitle(Shortcut.drafts.title)
    }
    private func row(_ draft: ServerDraft) -> some View {
        let room = store.rooms.conversations.first { $0.id == draft.conversationID }
        return HStack(alignment: .top, spacing: 10) {
            Avatar(room: room, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(room?.name ?? "Conversation").font(.body.weight(.semibold)).lineLimit(1)
                    if draft.threadID != nil { Text("· Thread").font(.callout).foregroundStyle(.secondary).fixedSize() }
                    Spacer(minLength: 8)
                    if draft.updatedAt != .distantPast {
                        Text(ShortcutList.time(draft.updatedAt)).font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                }
                Text(TextStyleRange.plain(draft.text, draft.formatting)).font(.body).lineLimit(2).frame(
                    maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
