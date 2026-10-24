import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// A Drive file picked from the @ list: offered in its own section, put in as its title, and sent as Google Chat's web
/// sends it.
@MainActor struct DriveChipTests {
    static let plan = DriveFile(id: "f1", title: "Plan", mimeType: "application/vnd.google-apps.document")
    /// DRIVE_FILE over the title, render-if-possible, inline; metadata {1 id, 2 title, 9 false, 12 {}, 14 type}; and the
    /// message says it needs Drive chips (feature 4), as the server records.
    @Test func aDriveChipIsSentAsGoogleChatSendsIt() throws {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .drive(Self.plan), start: 4, length: 4)])
        let chip = try #require(sent.first { $0.type == .driveFile })
        #expect(
            chip.startIndex == 4 && chip.length == 4 && chip.chipRenderType == .renderIfPossible
                && chip.inlineRenderFormat == 1)
        #expect(
            chip.driveMetadata.id == "f1" && chip.driveMetadata.title == "Plan"
                && chip.driveMetadata.mimeType == Self.plan.mimeType)
        #expect(chip.driveMetadata.hasField9 && !chip.driveMetadata.field9 && chip.driveMetadata.hasField12)
        #expect(
            sent.first { $0.type == .requiredMessageFeaturesMetadata }?.requiredMessageFeaturesMetadata.requiredFeatures
                == [4])
    }
    /// The @ list's Files section, after people and spaces: files the server found for the query. Picking one puts its
    /// title in as a chip and a space after it.
    @Test func theAtListOffersFilesAndPickingOneMakesItsChip() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var asked: [String] = []
        view.needMentionResults = { asked.append($0) }
        view.load("", [])
        view.insertText("see @pl", replacementRange: view.selectedRange())
        #expect(asked.last == "pl")
        view.driveFiles = Found(query: "pl", items: [Self.plan])
        #expect(view.mentionMatches == [.file(Self.plan)])
        view.insert(.file(Self.plan), replacing: try #require(view.mentionQuery?.range))
        #expect(view.string == "see Plan ")
        #expect(view.formatting == [TextStyleRange(style: .drive(Self.plan), start: 4, length: 4)])
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())  // edited inside: plain text again
        #expect(view.formatting.isEmpty)
    }
    @Test func theStoreAsksForFilesAndKeepsTheLatest() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.searchMentionResults("design", "road")
        await eventually { !store.lookups.driveFiles.items.isEmpty }
        #expect(store.lookups.driveFiles == Found(query: "road", items: [FakeBackend.driveFiles[0]]))
    }
    /// Google matches a file's contents too: the answer for the query shows as is, though no title contains it. While
    /// the answer for a newer query is on its way, the last one is narrowed to titles that contain it.
    @Test func filesShowAsTheServerFoundThem() {
        let notes = DriveFile(id: "f2", title: "notes.md", mimeType: "text/markdown")
        let found = Found(query: "w", items: [notes, Self.plan])
        #expect(MentionQuery.filter(files: found, by: "w") == [notes, Self.plan])
        #expect(MentionQuery.filter(files: found, by: "wp").isEmpty)
        #expect(MentionQuery.filter(files: Found(query: "p", items: [notes, Self.plan]), by: "pl") == [Self.plan])
    }
}
