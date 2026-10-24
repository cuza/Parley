import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// The @ list's Apps section: the conversation's own apps, as autocomplete_bots finds them with the members-only filter
/// (3), so mentioning one never adds an app. A mention of an app goes out as a bot's.
@MainActor struct AppMentionTests {
    static let poll = Person(id: "b1", name: "Poll")
    @Test func anAppsMentionIsABotsMentionBothWays() throws {
        let sent = try #require(
            DynamiteMapper.annotations([TextStyleRange(style: .appMention(userID: "b1"), start: 0, length: 5)]).first)
        #expect(
            sent.userMentionMetadata.id.id == "b1" && sent.userMentionMetadata.id.type == .bot
                && sent.userMentionMetadata.type == .mention)
        var message = Dynamite_Message.with {
            $0.id.messageID = "m"
            $0.textBody = "@Poll"
            $0.creator.userID.id = "me"
        }
        message.annotations = [sent]
        let mapped = try #require(DynamiteMapper.message(message, in: "space/s1", selfID: "me", people: [:]))
        #expect(mapped.formatting == [TextStyleRange(style: .appMention(userID: "b1"), start: 0, length: 5)])
    }
    @Test func theAtListOffersTheSpacesAppsUnderApps() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var asked: [String] = []
        view.needMentionResults = { asked.append($0) }
        view.mentionPeople = [Person(id: "p", name: "Pat")]
        view.load("", [])
        view.insertText("@p", replacementRange: view.selectedRange())
        view.mentionApps = Found(query: "p", items: [Self.poll])
        #expect(asked.last == "p")
        #expect(view.mentionMatches.map(\.id) == ["p:p", "a:b1"])
        #expect(MentionList.headers(view.mentionMatches) == [0: "People", 1: "Apps"])
        view.insert(.app(Self.poll), replacing: try #require(view.mentionQuery?.range))
        #expect(view.string == "@Poll ")
        #expect(view.formatting == [TextStyleRange(style: .appMention(userID: "b1"), start: 0, length: 5)])
    }
}
