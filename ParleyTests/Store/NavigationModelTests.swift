import Foundation
import Testing

@testable import Parley
@testable import ParleyDomain

/// Navigation on its own, without a store: the side pane's transitions and the back and forward lists.
@MainActor struct NavigationModelTests {
    private let maria = Person(id: "maria", name: "Maria")

    /// An app's dialog shows in its conversation's own window while one is open, and in the main window otherwise.
    @Test func aDialogShowsInItsConversationsOwnWindow() {
        let navigation = NavigationModel()
        #expect(navigation.window(for: "design") == nil)
        navigation.windowOpened("design")
        #expect(navigation.window(for: "design") == "design")
        #expect(navigation.window(for: "launch") == nil)
        navigation.windowClosed("design")
        #expect(navigation.window(for: "design") == nil)
    }
    @Test func aPersonsDetailsCoverThePaneAndClosingThemShowsItAgain() {
        var pane = SidePane()
        pane.toggleInfo()
        pane.showPerson(maria)
        #expect(pane.person == maria && pane.info)
        pane.closePerson()
        #expect(pane == SidePane(content: .info))
        pane.openThread("t1")
        pane.showPerson(maria)
        pane.showPerson(Person(id: "alex", name: "Alex"))  // another person replaces the first, over the same thread
        #expect(pane.person?.id == "alex" && pane.thread == "t1")
        pane.closeThread()
        #expect(pane == SidePane(content: .person(Person(id: "alex", name: "Alex"), over: nil)))
    }
    @Test func openingAThreadReplacesAPersonAndTheInfoPanel() {
        var pane = SidePane(content: .person(maria, over: .info), threads: true)
        pane.openThread("t1")
        #expect(pane == SidePane(content: .thread("t1"), threads: true))
        #expect(pane.person == nil && !pane.info && pane.thread == "t1")
    }
    @Test func toggleInfoOverAPersonGoesBackToInfo() {
        var pane = SidePane(content: .person(maria, over: .thread("t1")), threads: true)
        pane.toggleInfo()
        #expect(pane == SidePane(content: .info))  // in place of the thread and the Threads list
        pane.toggleInfo()
        #expect(pane == SidePane())
        pane.openThread("t1")
        pane.toggleInfo()
        #expect(pane.info && pane.thread == nil)
    }
    @Test func closingInfoOrAThreadLeavesTheOtherAlone() {
        var pane = SidePane(content: .thread("t1"))
        pane.closeInfo()
        #expect(pane.thread == "t1")
        pane.closeThread()
        #expect(pane == SidePane())
        pane = SidePane(content: .person(maria, over: .info))
        pane.closeInfo()
        #expect(pane.person == maria && !pane.info)
    }
    @Test func eachWindowHasItsOwnPaneAndTheMainThreadSavesDrafts() {
        let navigation = NavigationModel()
        var leaves = 0
        navigation.left = { leaves += 1 }
        navigation.setPane("design") { $0.openThread("d4") }
        #expect(navigation.pane("design").thread == "d4" && navigation.threadID == nil && leaves == 0)
        navigation.setPane(nil) { $0.openThread("t1") }
        navigation.setPane(nil) { $0.showPerson(maria) }  // the thread stays open under the person
        #expect(navigation.threadID == "t1" && leaves == 1)
        navigation.setPane(nil) { $0.closeThread() }
        navigation.selectedID = "general"
        navigation.selectedID = "general"
        navigation.shortcut = .home
        #expect(leaves == 4)
    }
    @Test func backAndForwardWorkAsInABrowser() {
        let navigation = NavigationModel()
        navigation.visit(.conversation("a"), from: nil)  // nothing open yet: nothing to go back to
        navigation.visit(.conversation("b"), from: .conversation("a"))
        navigation.visit(.conversation("b"), from: .conversation("b"))
        navigation.visit(.shortcut(.home), from: .conversation("b"))
        #expect(navigation.backPlaces == [.conversation("a"), .conversation("b")])
        #expect(navigation.back(from: .shortcut(.home)) == .conversation("b"))
        #expect(navigation.canGoForward && navigation.forward(from: .conversation("b")) == .shortcut(.home))
        #expect(navigation.forward(from: .shortcut(.home)) == nil)
        _ = navigation.back(from: .shortcut(.home))
        navigation.forget("a")
        #expect(navigation.backPlaces.isEmpty && navigation.forwardPlaces == [.shortcut(.home)])
        for index in 0..<120 { navigation.visit(.conversation("c\(index)"), from: .conversation("p\(index)")) }
        #expect(navigation.backPlaces.count == 100 && navigation.forwardPlaces.isEmpty)
    }
}
