import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// A person's detailed view, as Google Chat's: their reporting line, what we recently shared and their files, each read
/// from Google Contacts' answer; opened in the side pane from their card.
@MainActor struct PersonDetailsTests {
    static let build = "contacts_build"
    @Test func reportsAndTheManagementChainAreRead() throws {
        let pat: [Any] = ["Pat Doe", "1", "https://example.invalid/pat.jpg", "Engineer"]
        let kim: [Any] = ["Kim Lee", "2", NSNull(), ""]
        let request = ContactReports(id: "9", email: nil)
        #expect(request.arguments(build: Self.build)[2] as? [String] == [])  // the id is enough
        #expect((request.arguments(build: Self.build)[0] as? [[Any]])?[0][2] as? String == Self.build)
        let top = try request.reply([[NSNull(), [pat, kim], "", 3, NSNull(), NSNull()]])
        #expect(
            top.reports == [
                .init(
                    id: "1", name: "Pat Doe", avatarURL: URL(string: "https://example.invalid/pat.jpg"),
                    title: "Engineer"),
                .init(id: "2", name: "Kim Lee", avatarURL: nil, title: nil),
            ])
        #expect(top.reportCount == 3 && top.managers.isEmpty)
        let report = try request.reply([[NSNull(), [], "", 0, NSNull(), [[pat], kim]]])
        #expect(report.reports.isEmpty && report.managers.map(\.id) == ["1"])
    }
    @Test func recentInteractionsAndFilesAreRead() throws {
        let event: [Any] = [
            1, "https://example.invalid/event", "Review", NSNull(), NSNull(), [1_790_000_000], [NSNull(), "Review"],
        ]
        let mail: [Any] = [
            2, "https://example.invalid/mail", "Notes", NSNull(), [NSNull(), [true, false, "0"]], [1_790_000_000],
            [NSNull(), "Notes"],
        ]
        let recent = try ContactRecent(id: "9", email: "pat@example.com").reply([[[event, mail, [3, "x", "Other"]]]])
        #expect(recent.map(\.kind) == [.event, .email] && recent.map(\.title) == ["Review", "Notes"])
        #expect(recent[0].date == Date(timeIntervalSince1970: 1_790_000_000))
        let file: [Any] = ["Plan", "https://example.invalid/plan", "https://example.invalid/icon", [1_790_000_000, 5]]
        let files = try ContactFiles(id: "9").reply([[file], "https://example.invalid/drive"])
        #expect(
            files.files == [
                .init(
                    kind: .file, title: "Plan", url: URL(string: "https://example.invalid/plan")!,
                    date: Date(timeIntervalSince1970: 1_790_000_000))
            ])
        #expect(files.moreFiles == URL(string: "https://example.invalid/drive"))
    }
    /// Show Details puts the person over what the pane shows; ⇧⌘I from there goes back to the info panel, and opening a
    /// thread replaces them.
    @Test func detailsOpenInTheSidePane() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let maria = Person(id: "maria", name: "Maria Chen")
        store.showDetails(maria)
        #expect(store.navigation.pane(nil).person == maria && ChatView.paneShown(store.navigation.pane(nil), room: nil))
        store.toggleInfo()
        #expect(store.navigation.pane(nil).person == nil && store.navigation.pane(nil).info)
        store.showDetails(maria, window: "design")
        #expect(store.navigation.pane("design").person == maria && store.navigation.pane(nil).person == nil)
        let details = try #require(await store.personDetails(of: maria))
        #expect(details.reports.map(\.name) == ["Sam Okafor"] && details.recent.count == 2 && details.moreFiles != nil)
    }
}
