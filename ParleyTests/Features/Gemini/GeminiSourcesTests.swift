import AppKit
import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// A Gemini answer's sources: the "N Sources" line under the text, and its menu of sources to open.
@MainActor struct GeminiSourcesTests {
    private func source(_ title: String, _ url: String, _ kind: Dynamite_ContextSource.Kind) -> Dynamite_ContextSource {
        .with {
            $0.title = title
            $0.url = url
            $0.kind = kind
        }
    }
    private func citation(_ start: Int32, _ length: Int32, id: String? = nil, _ sources: [Dynamite_ContextSource])
        -> Dynamite_Annotation
    {
        .with { annotation in
            annotation.type = .contextSource
            annotation.startIndex = start
            annotation.length = length
            annotation.chipRenderType = .render
            annotation.contextSourceMetadata = .with { metadata in
                if let id { metadata.citationID = id }
                metadata.sources = sources
            }
        }
    }
    static let mail = "https://mail.google.com/mail/#all/abc", event = "https://www.google.com/calendar/event?eid=xyz"
    private func answer(_ annotations: [Dynamite_Annotation]) throws -> Message {
        let proto = Dynamite_Message.with { built in
            built.id.messageID = "a1"
            built.id.parentID.topicID.topicID = "q1"
            built.creator.userID.id = "gemini"
            built.textBody = "The event was on Tuesday."
            built.annotations = annotations
        }
        return try #require(DynamiteMapper.message(proto, in: "dm/g", selfID: "me", people: [:]))
    }

    @Test func theAnswersSourcesComeFromItsZeroLengthCitationsInOrder() throws {
        let gmail = source("Updated invitation", Self.mail, .gmail)
        let calendar = source("Open House", Self.event, .calendar)
        let message = try answer([
            citation(0, 0, [gmail]), citation(0, 0, [calendar]), citation(0, 25, id: "1", [gmail, calendar]),
        ])
        #expect(
            message.sources == [
                Source(title: "Updated invitation", url: URL(string: Self.mail)!, kind: .gmail),
                Source(title: "Open House", url: URL(string: Self.event)!, kind: .calendar),
            ])
        #expect(message.text == "The event was on Tuesday." && message.formatting.isEmpty)
    }
    /// Several messages from one space can share a link: Google Chat lists every source, so Parley keeps them all.
    @Test func everyListedSourceIsKeptEvenWhenTwoShareALink() throws {
        let room = "https://chat.google.com/room/AAAA/t1/m1"
        let message = try answer([
            citation(0, 0, [source("Town Hall", room, .chat)]), citation(0, 0, [source("Town Hall", room, .chat)]),
            citation(0, 0, [source("Engineering", "https://chat.google.com/room/BBBB/t2/m2", .chat)]),
        ])
        #expect(message.sources.map(\.title) == ["Town Hall", "Town Hall", "Engineering"])
    }
    /// Google Chat sends some chat sources over http: they are kept, on https.
    @Test func aChatSourceSentOverHTTPIsKeptOnHTTPS() throws {
        let message = try answer([
            citation(0, 0, [source("Town Hall", "http://chat.google.com/room/AAAA/t1/m1", .chat)])
        ])
        #expect(message.sources.map(\.url) == [URL(string: "https://chat.google.com/room/AAAA/t1/m1")!])
    }
    /// A source that is a Google Chat message opens here, as a Chat link in a message does; anything else in the browser.
    @Test func aChatSourceOpensInParley() {
        var opened: [String] = []
        let chat = URL(string: "https://chat.google.com/room/AAAA/t1/m1")!
        let mail = URL(string: Self.mail)!
        MessageRowView.open(
            source: chat, chatLink: { _, _ in opened.append("app") }, browser: { _ in opened.append("browser") })
        MessageRowView.open(
            source: mail, chatLink: { _, _ in opened.append("app") }, browser: { _ in opened.append("browser") })
        #expect(opened == ["app", "browser"])
    }
    @Test func withoutZeroLengthCitationsTheRangedOnesGiveTheSourcesOnce() throws {
        let gmail = source("Mail", Self.mail, .gmail)
        let docs = source("Plan", "https://docs.google.com/document/d/1", .docs)
        let message = try answer([citation(0, 9, id: "1", [gmail, docs]), citation(10, 5, id: "2", [docs])])
        #expect(message.sources.map(\.title) == ["Mail", "Plan"] && message.sources.map(\.kind) == [.gmail, .docs])
    }
    @Test func theBubbleEndsWithTheSourcesLineWhoseMenuOpensEach() throws {
        var message = Message.fixture(
            "The event was on Tuesday.", id: "a", from: .fixture("gemini", name: "Ask Gemini"), in: "dm/g")
        message.sources = [
            Source(title: "Updated invitation", url: URL(string: Self.mail)!, kind: .gmail),
            Source(title: "Open House", url: URL(string: Self.event)!, kind: .calendar),
        ]
        let layout = RowLayout.make(TimelineRow.rows([message])[0], width: 600, own: false, kind: .direct)
        let line = try #require(layout.sources)
        let text = try #require(layout.text)
        #expect(layout.bubble.contains(line) && line.minY > text.maxY)
        #expect(RowLayout.sourcesText(message.sources).string.hasSuffix("2 Sources"))
        let menu = MessageRowView.sourcesMenu(message.sources) { _ in }
        #expect(
            menu.items.map(\.title) == ["Updated invitation", "Open House"] && menu.items.allSatisfy { $0.image != nil }
        )
        if #available(macOS 27, *) {  // menus hide item images unless an item asks to show its own
            #expect(menu.items.allSatisfy { $0.preferredImageVisibility == .visible })
        }
    }
}
