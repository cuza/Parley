import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Composer state on its own, without a store or a backend.
@MainActor struct DraftsModelTests {
    private let scope = "launch/timeline"

    @Test func draftedScopesChangeOnlyWhenADraftStartsOrClears() {
        let drafting = DraftsModel()
        #expect(drafting.set("h", formatting: [], in: scope))
        #expect(drafting.drafted == [scope])
        #expect(!drafting.set("h", formatting: [], in: scope))  // nothing changed
        #expect(drafting.set("  ", formatting: [], in: scope))
        #expect(drafting.drafted.isEmpty)  // blank is no draft
        drafting.text["other/timeline"] = "hi"
        drafting.clear("other/timeline")
        #expect(drafting.drafted.isEmpty && drafting.formatting.isEmpty)
    }
    @Test func anEditBorrowsTheComposerAndGivesTheDraftBack() {
        let drafting = DraftsModel()
        drafting.text[scope] = "my draft"
        drafting.quoting[scope] = QuotedMessage(sender: "Maria", text: "quoted")
        drafting.startEdit("m1", in: scope)
        _ = drafting.set("sent text", formatting: [], in: scope)
        drafting.startEdit("m1", in: scope)  // a second edit keeps the first held draft
        #expect(drafting.isEditing(scope) && drafting.quoting[scope] == nil)
        #expect(drafting.finishEdit(scope))
        #expect(drafting.text[scope] == "my draft" && !drafting.isEditing(scope))
        #expect(!drafting.finishEdit(scope))
    }
    @Test func aSendSpendsGooglesCopy() {
        let drafting = DraftsModel()
        drafting.server[scope] = ServerDraft(id: "d1", conversationID: "launch", threadID: nil, text: "hi")
        drafting.edits[scope] = .now
        #expect(drafting.spend(scope) == "d1")
        #expect(
            drafting.server.isEmpty && drafting.edits.isEmpty && drafting.spent == ["d1"] && drafting.sends[scope] == 1)
        #expect(drafting.spend(scope) == nil && drafting.sends[scope] == 2)
    }
    @Test func onlyPlainTextCanBeScheduledAndTheListStaysSoonestFirst() {
        let drafting = DraftsModel()
        #expect(!drafting.canSchedule(scope))
        drafting.text[scope] = "later"
        #expect(drafting.canSchedule(scope))
        drafting.editing[scope] = "m1"
        #expect(!drafting.canSchedule(scope))
        let soon = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        drafting.keepScheduled(
            ServerDraft(id: "b", conversationID: "launch", threadID: nil, text: "b", schedule: .init(at: late)))
        drafting.keepScheduled(
            ServerDraft(id: "a", conversationID: "launch", threadID: nil, text: "a", schedule: .init(at: soon)))
        drafting.keepScheduled(
            ServerDraft(id: "b", conversationID: "launch", threadID: "t", text: "b", schedule: .init(at: late)))
        #expect(drafting.scheduled.map(\.id) == ["a", "b"])
        #expect(drafting.scheduled(in: "launch", thread: "t").map(\.id) == ["b"])
    }
}
