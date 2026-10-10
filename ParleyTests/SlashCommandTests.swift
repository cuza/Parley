import AppKit
import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

private let help = SlashCommand(appID: "app1", appName: "Helper", appAvatar: URL(string: "https://example.invalid/a.png"), name: "/help", id: 1,
                                description: "Show help")
private let poll = SlashCommand(appID: "app2", appName: "Poller", name: "/poll", id: 7, description: "Start a poll", opensDialog: true)
private let pollHelp = SlashCommand(appID: "app2", appName: "Poller", name: "/poll_help", id: 2, description: "Poll help")

private func listed(_ app: String, _ name: String, id: Int64, installed: Bool = true, kind: Int32? = 2, dialog: Bool = false) -> Dynamite_IntegrationAction {
    .with { a in
        a.appCommand.app.userID.id = app; a.appCommand.app.userID.type = .bot; a.appCommand.app.name = "App " + app
        a.appCommand.app.avatarURL = "https://example.invalid/\(app).png"
        a.appCommand.command.name = name; a.appCommand.command.id = id; a.appCommand.command.description_p = "d" + name
        a.appCommand.command.opensDialog = dialog
        if let kind { a.appCommand.command.kind.kind = kind }
        a.appCommand.installed = installed
    }
}

/// Network-stubbed: joins the serialized AuthTests suite (the stub registry is global).
extension AuthTests {
    @Test func slashCommandsAreSearchedAsWebDoesAndAppsOutsideTheSpaceLeftOut() async throws {
        let response = Dynamite_SearchIntegrationActionsResponse.with {
            $0.actions = [
                .with { $0.builtin.kind = 1; $0.builtin.label = "x" },                // a built-in (Drive…)
                listed("a1", "/help", id: 1),
                listed("a1", "", id: 3, kind: 1),                                     // a quick command: no name
                listed("a1", "", id: 4, kind: 0),                                     // a message action
                listed("a2", "/other", id: 1, installed: false),                      // an app not in the space
                listed("a3", "/add", id: 5, kind: nil, dialog: true),                 // some apps leave the kind out
                listed("a1", "/help", id: 1),                                         // repeated
            ]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(response), try Self.proto(Dynamite_SearchIntegrationActionsResponse())])
        let found = try await backend.slashCommands(in: "space/AAA", matching: "he", toApp: false)
        #expect(found == [SlashCommand(appID: "a1", appName: "App a1", appAvatar: URL(string: "https://example.invalid/a1.png"), name: "/help", id: 1, description: "d/help"),
                          SlashCommand(appID: "a3", appName: "App a3", appAvatar: URL(string: "https://example.invalid/a3.png"), name: "/add", id: 5, description: "d/add", opensDialog: true)])
        _ = try await backend.slashCommands(in: "dm/BBB", matching: "", toApp: true)
        let requests = try exchange.requests.filter { $0.url?.path == "/api/search_integration_actions" }
            .map { try Dynamite_SearchIntegrationActionsRequest(serializedBytes: Self.body($0)) }
        #expect(requests.count == 2)
        // A space: {1 "he", 2 GroupId {1 SpaceId {1 id}}, 3 25, 4 [2], 5 1, 6 3, 7 {1 5}, 8 {1 [8]}, 100 header}, as web sends it.
        var space = requests[0]
        #expect(space.hasRequestHeader)
        space.clearRequestHeader()
        let bytes: [UInt8] = try space.serializedBytes()
        #expect(bytes == [0x0A, 0x02, 0x68, 0x65, 0x12, 0x07, 0x0A, 0x05, 0x0A, 0x03, 0x41, 0x41, 0x41, 0x18, 0x19, 0x22, 0x01, 0x02,
                                                         0x28, 0x01, 0x30, 0x03, 0x3A, 0x02, 0x08, 0x05, 0x42, 0x03, 0x0A, 0x01, 0x08])
        // An app's DM: its dm id, kind 1 on surface 2.
        #expect(requests[1].groupID.dmID.dmID == "BBB" && requests[1].kinds == [1] && requests[1].surface == 2 && requests[1].query == "")
    }
    @Test func aPickedCommandGoesAsTheSlashCommandAnnotationOverItsName() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([topic])
        let text = "/poll \"Tea\" \"Coffee\""
        _ = try await backend.send(MessageDraft(text: text, localID: "local-1", formatting: [TextStyleRange(style: .slashCommand(poll), start: 0, length: 5)]),
                                   to: "space/AAA", thread: nil)
        let sent = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/create_topic" })))
        #expect(sent.textBody == text)
        #expect(sent.messageInfo.acceptFormatAnnotations)   // as web sends it, with only the command
        #expect(sent.annotations.count == 1)
        // {1 16, 2 0, 3 5 (the name only), 15 {1 {1 app, 2 1 bot}, 2 2 invoke, 3 name, 4 id, 5 "", 6 dialog, 7 description, 8 app, 9 avatar, 10 false}}
        let annotation = try #require(sent.annotations.first)
        #expect(annotation.type == .slashCommand && annotation.startIndex == 0 && annotation.length == 5)
        let expected: [UInt8] = [0x0A, 0x08, 0x0A, 0x04] + Array("app2".utf8) + [0x10, 0x01, 0x10, 0x02, 0x1A, 0x05] + Array("/poll".utf8)
            + [0x20, 0x07, 0x2A, 0x00, 0x30, 0x01, 0x3A, 0x0C] + Array("Start a poll".utf8) + [0x42, 0x06] + Array("Poller".utf8)
            + [0x4A, 0x00, 0x50, 0x00]
        let metadata: [UInt8] = try annotation.slashCommandMetadata.serializedBytes()
        #expect(metadata == expected)
    }
}

struct SlashCommandAnnotationTests {
    @Test func onlyACommandAtTheStartIsSentAndNeverAsFormatting() {
        #expect(DynamiteMapper.slashCommand(TextStyleRange(style: .slashCommand(help), start: 1, length: 5)) == nil)
        #expect(DynamiteMapper.slashCommand(TextStyleRange(style: .bold, start: 0, length: 5)) == nil)
        #expect(DynamiteMapper.annotations([TextStyleRange(style: .slashCommand(help), start: 0, length: 5)]).isEmpty)   // drafts and edits leave it out
    }
    /// The command's message as it comes back: only the sender sees it (20 = 2), the app's echo row (19 type 5), and the
    /// metadata trimmed to app, kind, name, id and dialog flag.
    @Test func aReceivedCommandMessageDrawsAsTypedWithNoGaps() throws {
        let proto = Dynamite_Message.with { m in
            m.id.messageID = "m1"; m.creator.userID.id = "me"; m.textBody = "/help x"
            m.annotations = [.with { a in
                a.type = .slashCommand; a.startIndex = 0; a.length = 5
                a.slashCommandMetadata = .with { $0.appID.id = "app1"; $0.appID.type = .bot; $0.type = 2; $0.name = "/help"; $0.commandID = 1; $0.opensDialog = false }
            }]
            m.botResponses = [.with { $0.type = 5; $0.bot.userID.id = "app1" }]
        }
        let withState = try Dynamite_Message(serializedBytes: try proto.serializedBytes() as [UInt8] + [0xA0, 0x01, 0x02])   // field 20 = 2
        let message = try #require(DynamiteMapper.message(withState, in: "space/AAA", selfID: "me", people: [:]))
        #expect(message.text == "/help x")
        #expect(message.attachments.isEmpty)
        #expect(MessageCoverage.gaps(withState, selfID: "me") == [])
    }
}

@MainActor struct SlashCommandComposerTests {
    @Test func aSlashOnlyAtTheStartAndBeforeAnySpaceStartsACommand() {
        #expect(MentionQuery.slash(in: "/", caret: 1) == MentionQuery(range: NSRange(location: 0, length: 1), text: "", command: true))
        #expect(MentionQuery.slash(in: "/po", caret: 3)?.text == "po")
        #expect(MentionQuery.slash(in: "/poll x", caret: 7) == nil)   // arguments now
        #expect(MentionQuery.slash(in: "a /po", caret: 5) == nil)
        #expect(MentionQuery.slash(in: "", caret: 0) == nil)
    }
    @Test func filteringMatchesInsideTheNameOrAppPrefixesFirst() {
        let all = [pollHelp, help, poll]
        #expect(SlashCommand.filter(all, by: "").map(\.name) == ["/help", "/poll", "/poll_help"])
        #expect(SlashCommand.filter(all, by: "HEL").map(\.name) == ["/help", "/poll_help"])
        #expect(SlashCommand.filter(all, by: "po").map(\.name) == ["/poll", "/poll_help"])
        #expect(SlashCommand.filter(all, by: "zz").isEmpty)
        #expect(SlashCommand.filter(all, by: "oller").map(\.name) == ["/poll", "/poll_help"])   // the app's name
    }
    @Test func typingASlashAsksForCommandsAndListsTheMatches() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var asked: [String] = []
        view.needSlashCommands = { asked.append($0) }
        view.slashCommands = [help, poll, pollHelp]
        view.insertText("/", replacementRange: view.selectedRange())
        view.insertText("po", replacementRange: view.selectedRange())
        #expect(asked == ["", "po"])
        #expect(view.mentionQuery?.command == true)
        #expect(view.mentionMatches == [.command(poll), .command(pollHelp)])
    }
    @Test func pickingInsertsTheNameAndASpaceAndTheMessageCarriesTheCommand() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.slashCommands = [poll]
        view.insertText("/po", replacementRange: view.selectedRange())
        view.insert(.command(poll), replacing: view.mentionQuery!.range)
        #expect(view.string == "/poll ")
        #expect(view.formatting == [TextStyleRange(style: .slashCommand(poll), start: 0, length: 5)])
        #expect(view.mentionQuery == nil)
        view.insertText("\"Tea\"", replacementRange: view.selectedRange())   // arguments stay plain
        #expect(view.formatting == [TextStyleRange(style: .slashCommand(poll), start: 0, length: 5)])
        // A saved draft loads back with its command.
        let reloaded = ComposerTextView(usingTextLayoutManager: false)
        reloaded.load(view.draftText, view.formatting)
        #expect(reloaded.formatting == view.formatting)
    }
    @Test func editingTheNameOrTypingBeforeItMakesItPlainText() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("/poll x", [TextStyleRange(style: .slashCommand(poll), start: 0, length: 5)])
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.formatting.isEmpty)
        let before = ComposerTextView(usingTextLayoutManager: false)
        before.load("/poll x", [TextStyleRange(style: .slashCommand(poll), start: 0, length: 5)])
        before.setSelectedRange(NSRange(location: 0, length: 0))
        before.insertText("a", replacementRange: before.selectedRange())
        #expect(before.formatting.isEmpty)
    }
}

@MainActor struct SlashCommandStoreTests {
    @Test func aBareSlashStartsOverAndQueriesAddTheirCommandsOnce() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        await store.loadSlashCommands(id, query: "help")
        await store.loadSlashCommands(id, query: "help")
        #expect(store.slashCommands[id]?.map(\.name) == ["/shipyard_help", "/notebook_help"])
        await store.loadSlashCommands(id, query: "")
        await store.loadSlashCommands(id, query: "help")
        #expect(store.slashCommands[id]?.map(\.label) == ["Send a Meet link", "/deploy", "/shipyard_help", "/notebook_help", "Create issue"])
        #expect(await fake.slashCommandRequests.map(\.query) == ["help", "", "help"])
    }
    @Test func sendingADialogCommandOpensTheAppsDialogForItsMessage() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        let deploy = FakeBackend.slashCommands[0]
        store.setDraft("/deploy now", formatting: [TextStyleRange(style: .slashCommand(deploy), start: 0, length: 7)], conversation: id, thread: nil)
        await store.send(conversation: id)
        let sent = try #require(await fake.sentDrafts.last)
        #expect(sent.formatting == [TextStyleRange(style: .slashCommand(deploy), start: 0, length: 7)])
        let message = try #require(store.messages.last { $0.text == "/deploy now" })
        #expect(await fake.dialogSteps == ["open \(message.id) app=shipyard"])
        #expect(store.dialog?.context == DialogContext(message: message.id, app: "shipyard"))
    }
}

/// Commands in DMs: Google Chat lists every app's commands there (not only its members'), and its own actions.
extension AuthTests {
    @Test func aPersonsDMAsksForEveryAppsCommandsAndAnAppsDMForItsOwn() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_SearchIntegrationActionsResponse()),
                                                            try Self.proto(Dynamite_SearchIntegrationActionsResponse())])
        _ = try await backend.slashCommands(in: "dm/BBB", matching: "", toApp: false)
        _ = try await backend.slashCommands(in: "dm/CCC", matching: "", toApp: true)
        let requests = try exchange.requests.filter { $0.url?.path == "/api/search_integration_actions" }
            .map { try Dynamite_SearchIntegrationActionsRequest(serializedBytes: Self.body($0)) }
        #expect(requests.count == 2)
        // A person's DM: {1 "", 2 GroupId {3 DmId {1 id}}, 3 25, 4 [2] every app, 5 1, 6 1, 7 {1 5}, 8 {1 [8]}, 100 header}.
        var dm = requests[0]
        #expect(dm.hasRequestHeader)
        dm.clearRequestHeader()
        let bytes: [UInt8] = try dm.serializedBytes()
        #expect(bytes == [0x0A, 0x00, 0x12, 0x07, 0x1A, 0x05, 0x0A, 0x03, 0x42, 0x42, 0x42, 0x18, 0x19, 0x22, 0x01, 0x02,
                          0x28, 0x01, 0x30, 0x01, 0x3A, 0x02, 0x08, 0x05, 0x42, 0x03, 0x0A, 0x01, 0x08])
        // An app's DM: that app only (filter 1) on surface 2.
        #expect(requests[1].groupID.dmID.dmID == "CCC" && requests[1].kinds == [1] && requests[1].surface == 2)
    }
    @Test func aPickedCommandIsInvokedNotAdded() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([topic])
        _ = try await backend.send(MessageDraft(text: "/help", localID: "local-1", formatting: [TextStyleRange(style: .slashCommand(help), start: 0, length: 5)]),
                                   to: "space/AAA", thread: nil)
        let sent = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/create_topic" })))
        #expect(sent.annotations.first?.slashCommandMetadata.type == 2)   // invoke; Parley never adds an app
    }
    @Test func aQuickCommandsDialogNamesTheConversationAndTheCommand() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_InvokeDialogResponse.with { $0.dialog = DialogTests.card }),
                                                            try Self.proto(Dynamite_SubmitFormActionResponse())])
        let context = DialogContext(message: "space/AAA", app: "a1", command: 2)
        _ = try await backend.dialog(.open, context, action: nil, inputs: [])
        _ = try await backend.dialog(.cancel, context, action: nil, inputs: [])
        // invoke_dialog {2 app {1 id, 2 1 bot}, 3 GroupId {1 SpaceId {1 id}}, 4 {1 command, 2 2, 3 2}, 6 header}, as web sends Poll's.
        var open = try Dynamite_InvokeDialogRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/invoke_dialog" })))
        #expect(open.hasRequestHeader)
        open.clearRequestHeader()
        #expect(try open.serializedBytes() as [UInt8] == [0x12, 0x06, 0x0A, 0x02, 0x61, 0x31, 0x10, 0x01, 0x1A, 0x07, 0x0A, 0x05, 0x0A, 0x03, 0x41, 0x41, 0x41,
                                                         0x22, 0x06, 0x08, 0x02, 0x10, 0x02, 0x18, 0x02])
        // Closing it: submit_form_action {1 2, 3 app, 6 GroupId, 7 the same command, 9 header}, no message.
        var cancel = try Dynamite_SubmitFormActionRequest(serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/submit_form_action" })))
        cancel.clearRequestHeader()
        #expect(try cancel.serializedBytes() as [UInt8] == [0x08, 0x02, 0x1A, 0x06, 0x0A, 0x02, 0x61, 0x31, 0x10, 0x01, 0x32, 0x07, 0x0A, 0x05, 0x0A, 0x03, 0x41, 0x41, 0x41,
                                                           0x3A, 0x06, 0x08, 0x02, 0x10, 0x02, 0x18, 0x02])
    }
}

struct SlashCommandListingTests {
    @Test func theListingKeepsTheConversationsAppsQuickCommandsAndTheMeetLink() {
        let response = Dynamite_SearchIntegrationActionsResponse.with {
            $0.actions = [
                .with { $0.builtin.kind = 1; $0.builtin.label = "Attach Drive files" },   // no Drive picker in Parley
                .with { $0.builtin.kind = 6; $0.builtin.label = "Send a Meet link" },
                .with { $0.builtin.kind = 2; $0.builtin.label = "Create Doc"; $0.flag4 = true },
                listed("a1", "/help", id: 1),
                listed("a2", "/other", id: 4, installed: false),
                .with { a in a.appCommand = listed("a1", "", id: 3, kind: 1, dialog: true).appCommand; a.appCommand.command.displayName = "Create a poll" },
                .with { a in a.appCommand = listed("a2", "", id: 5, kind: 1).appCommand; a.appCommand.command.displayName = "Connect"; a.appCommand.installed = false },
                listed("a1", "", id: 6, kind: 0),                                       // a message action
            ]
        }
        let found = DynamiteMapper.slashCommands(response)
        #expect(found.map(\.label) == ["Send a Meet link", "/help", "Create a poll"])
        #expect(found[0].action == .meetLink)
        #expect(found[2].action == .quick && found[2].id == 3 && found[2].appID == "a1" && found[2].opensDialog)
    }
    @Test func quickCommandsAndActionsMatchByTheirTitle() {
        #expect(SlashCommand.filter([help, FakeBackend.meetLink], by: "meet").map(\.label) == ["Send a Meet link"])
        #expect(SlashCommand.filter([help, FakeBackend.meetLink], by: "").map(\.label) == ["/help", "Send a Meet link"])
    }
}

@MainActor struct SlashCommandDMTests {
    @Test func aPersonsDMListsOnlyTheMeetLink() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.loadSlashCommands("maria", query: "")
        // No app is in a DM with a person, so only Google Chat's own Meet link, as the conversation offers.
        #expect(store.slashCommands["maria"]?.map(\.label) == ["Send a Meet link"])
        #expect(await fake.slashCommandRequests.map(\.toApp) == [false])
        await store.loadSlashCommands("notebook", query: "")
        #expect(await fake.slashCommandRequests.last?.toApp == true)
    }
    @Test func aSpaceStillListsItsAppsCommands() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.loadSlashCommands("design", query: "")
        #expect(store.slashCommands["design"]?.map(\.label) == ["Send a Meet link", "/deploy", "/shipyard_help", "/notebook_help", "Create issue"])
    }
    @Test func pickingTheMeetLinkSendsOneAndOpensIt() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        var opened: [URL] = []
        store.openURL = { opened.append($0) }
        await store.start()
        await store.run(FakeBackend.meetLink, in: "maria")
        #expect(opened == [URL(string: "https://meet.google.com/abc-defg-hij")!])
        #expect(await fake.sentDrafts.last?.uploads.first?.call == .join)
    }
    @Test func pickingAQuickCommandOpensItsDialogInTheConversation() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.run(FakeBackend.createIssueCommand, in: "design")
        #expect(await fake.dialogSteps == ["open design app=shipyard"])
        #expect(store.dialog?.context == DialogContext(message: "design", app: "shipyard", command: 3))
        #expect(store.dialog?.conversation == "design")
    }
}

@MainActor struct SlashCommandPickTests {
    @Test func pickingAQuickCommandOrActionClearsTheSlashAndRunsIt() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var ran: [SlashCommand] = []
        view.runCommand = { ran.append($0) }
        view.slashCommands = [help, FakeBackend.meetLink]
        view.insertText("/mee", replacementRange: view.selectedRange())
        #expect(view.mentionMatches == [.command(FakeBackend.meetLink)])
        view.insert(.command(FakeBackend.meetLink), replacing: view.mentionQuery!.range)
        #expect(view.string == "")
        #expect(view.formatting.isEmpty)
        #expect(ran == [FakeBackend.meetLink])
    }
}
