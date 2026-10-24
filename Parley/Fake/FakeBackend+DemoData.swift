import AppKit
import ParleyData
import ParleyDomain

// The demo workspace: its people, conversations, messages, apps and their cards, and the pictures and audio it serves.
extension FakeBackend {
    private static let maria = Person(id: "maria", name: "Maria Chen", presence: .available)
    private static let alex = Person(id: "alex", name: "Alex Rivera", presence: .away)
    private static let assistant = Person(id: "assistant", name: "Assistant")

    /// What `init` starts with: the demo's conversations and messages, and what its options add.
    static func demoWorkspace(longHistory: Int, manyConversations: Int, formattedThread: Bool) -> (
        rooms: [Conversation], history: [Message]
    ) {
        let now = Date.now
        var rooms = demoRooms(manyConversations: manyConversations)
        var history = demoMessages(now: now)
        if formattedThread {
            rooms.append(
                Conversation(id: "assistant", name: "Assistant", kind: .direct, members: [Self.me, assistant]))
            history += formattedThreadMessages(now: now)
        }
        let lines = [
            "ok", "Deploying the new build now, will report back in a few minutes.", "https://example.com/pull/42",
            "Can you take a look at the failing check? It only fails on the second run, which makes me think the cache is involved somewhere.",
            "👍", "Merged.\nRolling out to staging first, then everywhere after lunch if nothing looks off.",
        ]
        history += (0..<longHistory).map { index in
            Message(
                id: MessageID("e\(index)"), conversationID: "engineering", sender: index % 3 == 0 ? Self.me : alex,
                text: "\(index) · \(lines[index % lines.count])",
                createdAt: now.addingTimeInterval(Double(index - longHistory) * 1_800))
        }
        return (rooms, history)
    }

    private static func demoRooms(manyConversations: Int) -> [Conversation] {
        let rooms = [
            Conversation(
                id: "design", name: "Design studio", kind: .space, members: [Self.me, maria, alex], unread: 2,
                pinned: true),
            Conversation(id: "maria", name: maria.name, kind: .direct, members: [Self.me, maria], pinned: true),
            Conversation(id: "alex", name: alex.name, kind: .direct, members: [Self.me, alex], unread: 1),
            Conversation(id: "launch", name: "Launch crew", kind: .group, members: [Self.me, maria, alex]),
            Conversation(id: "general", name: "General", kind: .space, members: [Self.me, maria, alex]),
            Conversation(id: "engineering", name: "Engineering", kind: .space, members: [Self.me, alex], muted: true),
            Conversation(
                id: "notebook", name: "Notebook", kind: .direct, members: [Self.me, Self.notebook], unread: 1,
                avatarURL: Self.notebookIcon, app: .bot),
            Conversation(
                id: "gemini", name: "Ask Gemini", kind: .direct, members: [Self.me, Self.gemini], app: .gemini),
            // A space with a guest from a personal account: Google Chat marks it, and the guest, "External".
            Conversation(
                id: "partners", name: "Partners", kind: .space,
                members: [
                    Person(id: Self.me.id, name: Self.me.name, presence: .available, organization: .customer("demo")),
                    Person(id: "maria", name: "Maria Chen", presence: .available, organization: .customer("demo")),
                    Person(id: "sam", name: "Sam Okafor", email: "sam@example.com", organization: .consumer),
                ],
                external: true),
        ]
        return rooms
            + stride(from: 1, through: manyConversations, by: 1).map { number in
                let person = Person(
                    id: PersonID("person\(number)"),
                    name: number % 7 == 0
                        ? "Person \(number) with a very long name that cannot fit in the sidebar" : "Person \(number)")
                return number.isMultiple(of: 2)
                    ? Conversation(
                        id: ConversationID("space\(number)"), name: "Space \(number)", kind: .space, members: [Self.me],
                        unread: number % 5 == 0 ? number : 0,
                        emoji: number % 3 == 0 ? "🚀" : nil)
                    : Conversation(
                        id: ConversationID("dm\(number)"), name: person.name, kind: .direct,
                        members: [Self.me, person], unread: number % 5 == 0 ? 1 : 0)
            }
    }

    private static func demoMessages(now: Date) -> [Message] {
        [
            Message(
                id: "d1", conversationID: "design", sender: maria,
                text: "Morning! I’ve been thinking about how we make this feel more at home on the Mac.",
                createdAt: now.addingTimeInterval(-3600)),
            Message(
                id: "d2", conversationID: "design", sender: maria,
                text: "A little less chrome, a little more room for the conversation.",
                createdAt: now.addingTimeInterval(-3550), reactions: [Reaction(emoji: "✨", people: ["me", "alex"])],
                starred: true),
            Message(
                id: "d3", conversationID: "design", sender: Self.me,
                text: "Agreed. Compact sidebar, native text, and threads that stay out of the way.",
                createdAt: now.addingTimeInterval(-3300), pinned: true),
            Message(
                id: "d4", conversationID: "design", sender: alex,
                text: "The keyboard shortcuts are the part I’m most excited about. ⌘K should get us anywhere \u{FFFD}",
                createdAt: now.addingTimeInterval(-900),
                reactions: [Reaction(emoji: Self.shipIt.text, people: ["maria"], custom: Self.shipIt)], replyCount: 2,
                formatting: [TextStyleRange(style: .customEmoji(Self.shipIt), start: 86, length: 1)]),
            Message(
                id: "r1", conversationID: "design", threadID: "d4", sender: maria,
                text: "Yes! And Escape to get right back to the conversation.", createdAt: now.addingTimeInterval(-800)),
            Message(
                id: "r2", conversationID: "design", threadID: "d4", sender: Self.me, text: "That’s the plan.",
                createdAt: now.addingTimeInterval(-750)),
            Message(
                id: "d6", conversationID: "design", sender: alex, text: "https://shipyard.example/pr/42",
                createdAt: now.addingTimeInterval(-1_200),
                attachments: [Self.shipyardPreview]),
            Message(
                id: "d7", conversationID: "design", sender: maria,
                text: "¡Qué bien! ¿Lo probamos con el equipo el jueves?", createdAt: now.addingTimeInterval(-1_000),
                translation: Translation(text: "Nice! Shall we try it with the team on Thursday?", from: "es")),
            Message(
                id: "d5", conversationID: "design", sender: maria,
                text:
                    "Try sending a message, adding a reaction, or opening the thread above. This workspace is a local demo.",
                createdAt: now.addingTimeInterval(-300)),
            Message(
                id: "n1", conversationID: "notebook", sender: Self.notebook,
                text: "Maria Chen mentioned you in a comment in Launch plan",
                createdAt: now.addingTimeInterval(-1_500), attachments: [Self.commentCard(maria: maria)]),
            Message(
                id: "m1", conversationID: "maria", sender: maria,
                text: "Do you have a moment to look at the new layout?", createdAt: now.addingTimeInterval(-1800)),
            Message(
                id: "m2", conversationID: "maria", sender: Self.me, text: "Absolutely. Send it over!",
                createdAt: now.addingTimeInterval(-1700)),
            Message(
                id: "m3", conversationID: "maria", sender: maria, text: "", createdAt: now.addingTimeInterval(-1650),
                attachments: [Self.demoVoice]),
            Message(
                id: "a1", conversationID: "alex", sender: alex, text: "The build is ready for a first look 👋",
                createdAt: now.addingTimeInterval(-600)),
            Message(
                id: "g1", conversationID: "general", sender: alex,
                text: "@Dave could you share the release notes before Friday?",
                createdAt: now.addingTimeInterval(-5400),
                replyCount: 1, formatting: [TextStyleRange(style: .mention(userID: Self.me.id), start: 0, length: 5)]),
            Message(
                id: "g1r", conversationID: "general", threadID: "g1", sender: maria,
                text: "I can draft the summary part.", createdAt: now.addingTimeInterval(-450)),
            // Ask Gemini: each question is a session, Gemini answering in its thread.
            Message(
                id: "gs1", conversationID: "gemini", sender: Self.me, text: "What's on my calendar tomorrow?",
                createdAt: now.addingTimeInterval(-9_000),
                replyCount: 1),
            Message(
                id: "gs1r", conversationID: "gemini", threadID: "gs1", sender: Self.gemini,
                text: "Tomorrow you have a Design review at 10:00 and the launch sync at 15:00.",
                createdAt: now.addingTimeInterval(-8_990)),
            Message(
                id: "gs2", conversationID: "gemini", sender: Self.me, text: "Summarize the launch plan",
                createdAt: now.addingTimeInterval(-90_000),
                replyCount: 1),
            Message(
                id: "gs2r", conversationID: "gemini", threadID: "gs2", sender: Self.gemini,
                text: "The launch plan ships the beta to the team on Thursday, then to everyone after a week of fixes.",
                createdAt: now.addingTimeInterval(-89_990)),
            Message(
                id: "l1", conversationID: "launch", sender: alex, text: "Launch plan for next week",
                createdAt: now.addingTimeInterval(-7_400),
                attachments: [
                    Attachment(
                        name: "Launch plan", contentType: "application/vnd.google-apps.document", kind: .link,
                        url: URL(string: "https://docs.google.com/document/d/demo/edit"))
                ]),
            Message(
                id: "l2", conversationID: "launch", sender: maria, text: "", createdAt: now.addingTimeInterval(-7_200),
                attachments: [
                    Attachment(
                        name: "Launch banner.png", contentType: "image/png", kind: .image,
                        thumbnailURL: URL(string: "https://parley.example/launch-banner.png"), width: 640, height: 360)
                ]),
        ]
    }

    /// A DM whose one thread reply is a long bold-and-list answer, like an assistant's.
    private static func formattedThreadMessages(now: Date) -> [Message] {
        var text = "Here are some things I can help with:\n"
        var formatting: [TextStyleRange] = []
        let items = [
            "Answer questions", "Summarize threads", "Draft replies", "Plan projects", "Brainstorm ideas",
            "Explain code",
            "Translate text", "Proofread writing", "Compare options", "Outline documents", "Write emails",
            "Find patterns",
            "Suggest names", "Create checklists", "Break down tasks", "Review plans", "Prepare meetings",
        ]
        for (index, item) in items.enumerated() {
            let start = text.utf16.count
            let line =
                "\(item): a short explanation of what that means in practice" + (index < items.count - 1 ? "\n" : "")
            text += line
            formatting += [
                TextStyleRange(style: .listItem, start: start, length: line.utf16.count),
                TextStyleRange(style: .bold, start: start, length: item.utf16.count),
            ]
        }
        return [
            Message(
                id: "q1", conversationID: "assistant", sender: Self.me, text: "What can you do?",
                createdAt: now.addingTimeInterval(-120), replyCount: 1),
            Message(
                id: "q1r", conversationID: "assistant", threadID: "q1", sender: assistant, text: text,
                createdAt: now.addingTimeInterval(-110),
                formatting: formatting),
        ]
    }

    /// A workspace's own emoji; its picture is `attachmentData`'s generated gradient.
    static let shipIt = CustomEmoji(
        id: "demo-ship-it", shortcode: "ship-it", imageURL: URL(string: "https://example.invalid/emoji/ship-it"))
    static let customEmoji = [
        shipIt,
        CustomEmoji(id: "demo-lgtm", shortcode: "lgtm", imageURL: URL(string: "https://example.invalid/emoji/lgtm")),
        CustomEmoji(
            id: "demo-party-parrot", shortcode: "party-parrot",
            imageURL: URL(string: "https://example.invalid/emoji/party-parrot")),
    ]
    /// The demo's Drive: recent files first, as Google Chat suggests them for "@" alone.
    static let driveFiles = [
        DriveFile(id: "demo-roadmap", title: "Roadmap", mimeType: "application/vnd.google-apps.document"),
        DriveFile(id: "demo-budget", title: "Budget 2027", mimeType: "application/vnd.google-apps.spreadsheet"),
        DriveFile(id: "demo-launch", title: "Launch deck", mimeType: "application/vnd.google-apps.presentation"),
    ]
    /// The demo directory: someone in no demo conversation, found only by name.
    static let directoryPerson = Person(id: "sam", name: "Sam Okafor", presence: .away)
    /// One the list leaves out, found only by searching: an organisation with more emoji than one read brings.
    static let searchOnlyEmoji = CustomEmoji(
        id: "demo-samba", shortcode: "samba", imageURL: URL(string: "https://example.invalid/emoji/samba"))
    /// The demo apps' commands, matched as the server does: the query anywhere in the name.
    static let slashCommands = [
        SlashCommand(
            appID: shipyard.id, appName: shipyard.name, appAvatar: shipyardIcon, name: "/deploy", id: 1,
            description: "Deploy a build", opensDialog: true),
        SlashCommand(
            appID: shipyard.id, appName: shipyard.name, appAvatar: shipyardIcon, name: "/shipyard_help", id: 2,
            description: "Show what Shipyard can do"),
        SlashCommand(
            appID: notebook.id, appName: notebook.name, appAvatar: notebookIcon, name: "/notebook_help", id: 1,
            description: "Show the help card"),
    ]
    /// Google Chat's own "Send a Meet link", listed first as the server lists it.
    static let meetLink = SlashCommand(
        appID: "", appName: "Google Meet", name: "", id: 0, description: "Send a new meeting link",
        action: .meetLink, title: "Send a Meet link")
    /// Shipyard's quick command: its "Create issue" dialog, with no message.
    static let createIssueCommand = SlashCommand(
        appID: shipyard.id, appName: shipyard.name, appAvatar: shipyardIcon, name: "", id: 3,
        description: "Open an issue", opensDialog: true, action: .quick, title: "Create issue")
    static let shipyard = Person(id: "shipyard", name: "Shipyard", avatarURL: shipyardIcon)
    /// Shipyard's dialog: a title, a priority menu, an assignee behind "More fields", Cancel and Create.
    static let createIssue: AppDialog = {
        func action(_ function: String) -> Data { CardActionPayload.data(function: function) }
        let page = URL(string: "https://shipyard.example/issues/new")!
        return AppDialog(
            title: "Create issue",
            card: Card(sections: [
                [
                    .field(
                        Card.Field(
                            name: "title", label: "Title", value: "", placeholder: "What needs doing?", required: true)),
                    .field(Card.Field(name: "details", label: "Details", value: "", multiline: true)),
                    .choice(
                        Card.Choice(
                            name: "priority", label: "Priority", style: .menu,
                            options: [
                                .init(text: "Low", value: "low", selected: false),
                                .init(text: "Normal", value: "normal", selected: true),
                                .init(text: "High", value: "high", selected: false),
                            ])),
                    .field(Card.Field(name: "assignee", label: "Assignee", value: "", placeholder: "Who takes it?")),
                    .collapse(more: "More fields", less: "More fields", hidden: 1),
                ]
            ]),
            primary: Card.Link(title: "Create", url: page, filled: true, action: action("create"), required: ["title"]),
            secondary: Card.Link(title: "Cancel", url: page, action: action("cancel")))
    }()
    // Demo apps. Their icons are drawn locally (`demoIcons`), as nothing is fetched in the demo.
    static let shipyardIcon = URL(string: "https://shipyard.example/icon.png")!
    static let notebookIcon = URL(string: "https://notebook.example/icon.png")!
    static let documentIcon = URL(string: "https://notebook.example/document.png")!
    static let notebook = Person(id: "notebook", name: "Notebook", avatarURL: notebookIcon)
    static let gemini = Person(id: "gemini", name: "Ask Gemini")
    /// The pictures behind the demo's icon URLs: a symbol on a coloured tile.
    @MainActor static var demoIcons: [(URL, NSImage)] {
        func tile(_ symbol: String, _ colour: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                colour.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
                let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(
                        .init(pointSize: 34, weight: .semibold).applying(.init(paletteColors: [.white])))
                glyph?.draw(in: rect.insetBy(dx: 14, dy: 14))
                return true
            }
        }
        return [
            (shipyardIcon, tile("shippingbox.fill", .systemIndigo)),
            (notebookIcon, tile("book.closed.fill", .systemOrange)),
            (documentIcon, tile("doc.text.fill", .systemBlue)),
        ]
    }
    /// A code-review app's preview of a link, as Google Chat sends one: a one-line linked title over a small grey line
    /// (its state in green), a description cut to two lines, and the app that made it.
    static let shipyardPreview: Attachment = {
        let link = URL(string: "https://shipyard.example/pr/42")!
        let title = "#42 Compact sidebar and native text"
        let label = "Open · design/parley · Author: alex"
        let start = title.utf16.count + 1
        let body =
            "Tightens the sidebar to native row heights, draws message text with the system text view so selection, links and "
            + "spelling behave like any Mac app, and keeps threads in a side pane that never covers the conversation."
        var card = Card(sections: [
            [
                .row(
                    icon: nil, round: false, label: nil, text: title + "\n" + label,
                    formatting: [
                        TextStyleRange(style: .link(link), start: 0, length: title.utf16.count),
                        TextStyleRange(style: .nowrap, start: 0, length: title.utf16.count),
                        TextStyleRange(style: .small, start: start, length: label.utf16.count),
                        TextStyleRange(style: .color(Card.secondaryText), start: start, length: label.utf16.count),
                        TextStyleRange(style: .color(0xFF1A_A64A), start: start, length: 4),
                    ]),
                .text(body, [], lines: 2),
                .links([
                    Card.Link(
                        title: "Create issue", url: link,
                        action: CardActionPayload.data(function: "create_issue", opensDialog: true),
                        dialog: true)
                ]),
            ]
        ])
        card.by = Card.Attribution(name: "Shipyard", icon: shipyardIcon)
        card.app = shipyard.id
        return Attachment(name: title, kind: .card, card: card)
    }()
    /// A documents app's comment notification: the document (the row opens it), the comment, a Reply box, and Reply and
    /// Resolve, which act in the card (`clickCard`), with Open at the end.
    static func commentCard(maria: Person) -> Attachment {
        func action(_ function: String) -> Data { CardActionPayload.data(function: function) }
        let document = URL(string: "https://notebook.example/d/launch-plan")!
        let comment = "Can we move the beta to Thursday? The release notes need one more pass."
        return Attachment(
            name: "Launch plan", kind: .card,
            card: Card(sections: [
                [
                    .row(
                        icon: documentIcon, round: false, label: nil, text: "Launch plan",
                        formatting: [TextStyleRange(style: .nowrap, start: 0, length: 11)], open: document)
                ],
                [.row(icon: nil, round: true, label: maria.name, text: comment, formatting: [])],
                [.field(Card.Field(name: "REPLY_TO_COMMENT", label: "Reply", value: ""))],
                [
                    .links([
                        Card.Link(title: "Reply", url: document, action: action("REPLY_TO_COMMENT")),
                        Card.Link(title: "Resolve", url: document, action: action("RESOLVE_COMMENT")),
                        Card.Link(title: "Open", url: document, trailing: true),
                    ])
                ],
            ]))
    }
    /// A voice message whose audio is a few seconds of humming tone (`attachmentData`).
    static let demoVoice = Attachment(
        name: "UserRecording_1700000000000.m4a", contentType: Voice.contentType, kind: .voice,
        url: URL(string: "https://example.com/demo-voice"),
        voice: Voice(
            duration: 6.4, waveform: (0..<64).map { 20 + Int(60 * abs(sin(Double($0) / 5))) },
            transcript: "Here’s a quick walkthrough of the new layout. Let me know what you think!"))
    /// Uncompressed 16-bit mono PCM in a WAV container.
    static func wav(_ samples: [Int16], rate: Int = 8_000) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let bytes = samples.count * 2
        var data = Data("RIFF".utf8) + le(UInt32(36 + bytes)) + Data("WAVEfmt ".utf8)
        data +=
            le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(rate)) + le(UInt32(rate * 2)) + le(UInt16(2))
            + le(UInt16(16))
        data += Data("data".utf8) + le(UInt32(bytes))
        samples.forEach { data += le($0) }
        return data
    }
}
