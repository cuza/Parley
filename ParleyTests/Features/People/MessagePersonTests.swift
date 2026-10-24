import AppKit
import Foundation
import SwiftProtobuf
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct MessagePersonTests {
    private func row(from sender: Person, kind: ConversationKind, offered: @escaping (Person) -> Void) -> MessageRowView
    {
        let view = MessageRowView()
        var actions = MessageRowActions()
        actions.message = offered
        view.configure(RowFixtures.row("hi", sender: sender), own: false, kind: kind, meID: "me", actions: actions)
        return view
    }
    @Test func theSendersMenuMessagesThem() throws {
        var picked: [Person] = []
        let alex = Person(id: "alex", name: "Alex Rivera", email: "alex@example.com")
        let menu = try #require(row(from: alex, kind: .space) { picked.append($0) }.personMenu())
        let item = try #require(menu.items.first { $0.title == "Message Alex Rivera" })
        menu.performActionForItem(at: menu.index(of: item))
        #expect(picked == [alex])
    }
    /// The card fills in its job title and local time after the menu opens; the menu item then fits the whole card,
    /// even when the answer is already known and arrives at once.
    @Test func theCardGrowsToFitItsDetails() async throws {
        let view = MessageRowView()
        var actions = MessageRowActions()
        actions.message = { _ in }
        actions.cardDetails = { _ in
            PersonCardDetails(title: "Product Designer", timeZone: TimeZone(identifier: "Europe/Lisbon"))
        }
        view.configure(
            RowFixtures.row("hi", sender: Person(id: "alex", name: "Alex Rivera", email: "alex@example.com")),
            own: false, kind: .space, meID: "me", actions: actions)
        let card = try #require(view.personMenu()?.items.first?.view)
        let bare = card.frame.height
        await eventually {
            card.layoutSubtreeIfNeeded()
            return card.frame.height > bare + 20
        }
        #expect(card.frame.height > bare + 20)  // two more lines
        #expect(abs(card.frame.height - card.fittingSize.height) < 1)
    }
    @Test func notOfferedForMeOrInAOneToOne() {
        #expect(row(from: Person(id: "me", name: "Dave"), kind: .group) { _ in }.personMenu() == nil)
        #expect(row(from: Person(id: "alex", name: "Alex"), kind: .direct) { _ in }.personMenu() == nil)
    }
}
