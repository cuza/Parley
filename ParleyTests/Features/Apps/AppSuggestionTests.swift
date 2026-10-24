import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// The private "install this app" card Google Chat shows under my own link when an app could preview it.
@MainActor
struct AppSuggestionTests {
    private func proto() -> Dynamite_Message {
        .with { built in
            built.id.messageID = "m1"
            built.id.parentID.topicID.topicID = "t1"
            built.creator.userID.id = "me"
            built.textBody = "https://example.com/pr/1"
            built.messageType = .userMessage
            built.botResponses = [
                .with { response in
                    response.type = 6
                    response.bot.name = "Example"
                    response.bot.avatarURL = "https://example.com/icon.png"
                }
            ]
        }
    }
    private func card(_ message: Message) -> Card? { message.attachments.first { $0.card?.dismiss != nil }?.card }

    @Test func aLinkMessageKeepsItsTextAndGetsThePrivateInstallCard() throws {
        let message = try #require(DynamiteMapper.message(proto(), in: "space/s", selfID: "me", people: [:]))
        #expect(message.text == "https://example.com/pr/1")
        let card = try #require(card(message))
        let items = card.sections.flatMap { $0 }
        #expect(
            items.first
                == .text(
                    "Only visible to you", [TextStyleRange(style: .color(Card.secondaryText), start: 0, length: 19)]))
        #expect(
            items.contains {
                if case .row(let icon, _, _, "Example", _, _, _, _, _) = $0 {
                    icon == URL(string: "https://example.com/icon.png")
                } else {
                    false
                }
            })
        #expect(
            items.contains(
                .text("To interactively preview this link, install Example and add it to this conversation.", [])))
        #expect(items.contains(.links([Card.Link(title: "Install", url: ChatLink.url(message: message.id)!)])))
        #expect(card.dismiss == "Don't install")
    }
    @Test func anAppSuggestionIsNotAnAppThatCouldNotAnswer() throws {
        var empty = proto()
        empty.textBody = ""
        let message = try #require(DynamiteMapper.message(empty, in: "space/s", selfID: "me", people: [:]))
        #expect(message.text != "Example couldn’t respond" && card(message) != nil)
    }
    @Test func dontInstallHidesTheCardForGood() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppSuggestionTests-\(UUID())"))
        let message = try #require(DynamiteMapper.message(proto(), in: "space/s", selfID: "me", people: [:]))
        let store = ChatStore(backend: FakeBackend())
        store.defaults = defaults
        store.apply(.messageUpserted(message))
        store.dismissCard(of: message)
        #expect(store.history.messages.first { $0.id == message.id }.map(card) == .some(nil))
        store.apply(.messageUpserted(message))  // loaded again
        #expect(store.history.messages.first { $0.id == message.id }.map(card) == .some(nil))
        let relaunched = ChatStore(backend: FakeBackend())
        relaunched.defaults = defaults
        relaunched.apply(.messageUpserted(message))
        #expect(relaunched.history.messages.first { $0.id == message.id }.map(card) == .some(nil))
        #expect(relaunched.history.messages.first { $0.id == message.id }?.text == message.text)
    }
}
