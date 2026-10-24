import Foundation

@testable import ParleyDomain

// Builders for the models tests make by hand. New tests use them and spell out only the fields they check, so a new
// model field changes one place. Tests whose point is a model's full shape (decoding, mapping, round trips) keep
// explicit values. Defaults are fixed: the same rows, days and order on every run.

/// Tests spell ids with interpolation as freely as with literals ("\(room)/t1/t1"); the app converts text to an id
/// explicitly.
extension ID: @retroactive ExpressibleByStringInterpolation {}

extension Person {
    static func fixture(_ id: PersonID = "maria", name: String = "Maria Chen") -> Person { Person(id: id, name: name) }
}

extension Message {
    /// The builders' fixed time. A test whose message must be new to the store (a notification, the newest row) passes `at: .now`.
    static let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
    static func fixture(
        _ text: String = "hi", id: MessageID = "m", from sender: Person = .fixture(),
        in conversation: ConversationID = "c",
        thread: ThreadID? = nil, at date: Date = fixtureDate, delivery: Delivery = .sent,
        attachments: [Attachment] = [],
        configure: (inout Message) -> Void = { _ in }
    ) -> Message {
        var message = Message(
            id: id, conversationID: conversation, threadID: thread, sender: sender, text: text, createdAt: date,
            delivery: delivery, attachments: attachments)
        configure(&message)
        return message
    }
}

extension Conversation {
    static func fixture(
        _ id: ConversationID = "space/s", kind: ConversationKind = .space, name: String = "Design",
        members: [Person] = [],
        unread: Int = 0, pinned: Bool = false, app: App? = nil
    ) -> Conversation {
        Conversation(id: id, name: name, kind: kind, members: members, unread: unread, pinned: pinned, app: app)
    }
}

extension Attachment {
    /// An attachment of `kind`, named "a.png" for an image and "a.pdf" for anything else unless the test names it.
    static func fixture(
        _ kind: Kind = .file, name: String? = nil, contentType: String = "", url: URL? = nil,
        width: Int? = nil, height: Int? = nil
    ) -> Attachment {
        Attachment(
            name: name ?? (kind == .image ? "a.png" : "a.pdf"), contentType: contentType, kind: kind, url: url,
            width: width, height: height)
    }
}
