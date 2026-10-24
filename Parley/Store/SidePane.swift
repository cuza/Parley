import Foundation
import ParleyDomain

/// A window's side pane: what it shows, and whether the conversation's Threads list is under it (an open thread or the
/// info panel shows over the list; closing the thread goes back to it).
struct SidePane: Equatable {
    indirect enum Content: Equatable {
        case info
        case thread(ThreadID)
        /// A person's details, over the info panel or a thread, which closing them shows again.
        case person(Person, over: Content?)
    }
    var content: Content?
    var threads = false

    var person: Person? { if case .person(let person, _)? = content { person } else { nil } }
    var info: Bool { base == .info }
    var thread: ThreadID? { if case .thread(let thread)? = base { thread } else { nil } }
    /// What shows under a person's details, or the content itself.
    private var base: Content? { if case .person(_, let over)? = content { over } else { content } }
    /// Replaces what shows under a person's details, or the content itself.
    private mutating func replaceBase(_ new: Content?) { content = person.map { .person($0, over: new) } ?? new }

    mutating func showPerson(_ person: Person) { content = .person(person, over: base) }
    mutating func closePerson() { content = base }
    /// A thread replaces a person's details and the info panel.
    mutating func openThread(_ thread: ThreadID) { content = .thread(thread) }
    mutating func closeThread() { if thread != nil { replaceBase(nil) } }
    mutating func closeInfo() { if info { replaceBase(nil) } }
    /// ⌘I: the info panel in place of a thread or the Threads list, or closed. Over a person's details it goes back to it.
    mutating func toggleInfo() {
        if person == nil, info {
            content = nil
            return
        }
        content = .info
        threads = false
    }
}
