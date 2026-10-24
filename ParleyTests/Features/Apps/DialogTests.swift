import AppKit
import Foundation
import SwiftProtobuf
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Apps' dialogs, as Google Chat runs them: a card button whose action opens a dialog asks the app for it
/// (`submit_form_action` type 3), the dialog shows in a sheet with its own buttons, a button sends every input (type 1),
/// and closing it tells the app (type 2). The app answers with the next step, what's wrong, or done (with a note).
struct DialogTests {

    @Test func aButtonThatOpensADialogCarriesItsActionAndTheApp() throws {
        let proto = Dynamite_Message.with { built in
            built.id.messageID = "m1"
            built.id.parentID.topicID.topicID = "m1"
            built.creator.userID.id = "bot"
            built.creator.userID.type = .bot
            built.appAttachments = [
                .with {
                    $0.card.sections = [
                        .with {
                            $0.widgets = [
                                .with {
                                    $0.buttons = [
                                        .with {
                                            $0.textButton = .with {
                                                $0.label = CardFixtures.text("Open")
                                                $0.onClick.action = CardFixtures.openDialog
                                            }
                                        }
                                    ]
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        let card = try #require(
            DynamiteMapper.message(proto, in: "dm/d", selfID: "me", people: [:])?.attachments.first?.card)
        #expect(card.links.map(\.dialog) == [true] && card.links.first?.action == CardFixtures.openDialog)
        #expect(card.app == "bot")  // the app that sent it, when the card doesn't name one
        var named = proto
        named.appAttachments[0].app.userID.id = "other"
        #expect(
            DynamiteMapper.message(named, in: "dm/d", selfID: "me", people: [:])?.attachments.first?.card?.app
                == "other")
    }
    @Test func aDialogCardMapsItsTitleBodyAndFooter() throws {
        let dialog = DynamiteMapper.dialog(CardFixtures.dialog, message: "dm/d/m1/m1")
        #expect(dialog.title == "T")
        #expect(dialog.card.sections == [[.field(Card.Field(name: "a", label: "A", value: ""))]])  // no header section
        #expect(
            dialog.primary?.title == "P" && dialog.primary?.filled == true
                && dialog.primary?.action == CardFixtures.submit)
        #expect(
            dialog.secondary?.title == "S" && dialog.secondary?.filled == nil
                && dialog.secondary?.action == CardFixtures.submit)
        #expect(
            DynamiteMapper.dialog(.with { $0.sections = CardFixtures.dialog.sections }, message: "dm/d/m1/m1").title
                == nil)  // the app's name then
    }
}

extension NetworkTests { @Suite struct DialogBackendTests: NetworkSuite {} }

extension NetworkTests.DialogBackendTests {
    private static let context = DialogContext(message: "dm/a/t1/h1", app: "bot")
    private func sent(_ exchange: StubExchange) throws -> (Dynamite_SubmitFormActionRequest, Data) {
        let request = try #require(exchange.requests.last)
        #expect(request.url?.path == "/api/submit_form_action")
        let body = Self.body(request)
        return (try Dynamite_SubmitFormActionRequest(serializedBytes: body), body)
    }
    @Test func openingADialogSendsTheButtonsActionAsGoogleChatDoes() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.proto(
                Dynamite_SubmitFormActionResponse.with {
                    $0.status.code = 0
                    $0.dialog = CardFixtures.dialog
                })
        ])
        let answer = try await backend.dialog(.open, Self.context, action: CardFixtures.openDialog, inputs: [])
        let (request, body) = try sent(exchange)
        // Fields 1–4 as Google Chat's web client sends them, then the header (field 9).
        var expected = Dynamite_SubmitFormActionRequest.with { form in
            form.type = 3
            form.messageID = request.messageID
            form.appID = .with {
                $0.id = "bot"
                $0.type = .bot
            }
            form.action = CardFixtures.openDialog
        }
        expected.requestHeader = request.requestHeader
        #expect(body == Data(try expected.serializedBytes() as [UInt8]))
        #expect(body.prefix(2) == Data([0x08, 0x03]))  // type 3: open a dialog
        #expect(request.messageID.messageID == "h1" && request.messageID.parentID.topicID.topicID == "t1")
        #expect(answer == .show(DynamiteMapper.dialog(CardFixtures.dialog, message: "dm/a/t1/h1")))
    }
    @Test func submittingSendsEveryInputAndClosingSendsNothingElse() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.proto(
                Dynamite_SubmitFormActionResponse.with {
                    $0.status.code = 0
                    $0.status.message = "Done."
                }),
            try Self.proto(
                Dynamite_SubmitFormActionResponse.with {
                    $0.status.code = 13
                    $0.status.message = "x"
                }),
        ])
        let inputs = [Card.Input(name: "a", value: "1"), Card.Input(name: "b", value: "")]
        #expect(
            try await backend.dialog(.submit, Self.context, action: CardFixtures.submit, inputs: inputs)
                == .close("Done."))
        let (submit, _) = try sent(exchange)
        #expect(submit.type == 1 && submit.action == CardFixtures.submit && submit.appID.id == "bot")
        #expect(
            submit.formInputs == [
                .with {
                    $0.name = "a"
                    $0.value = "1"
                    $0.field4 = 1
                },
                .with {
                    $0.name = "b"
                    $0.value = ""
                    $0.field4 = 1
                },
            ])
        // Close: type 2 with the message and app only; the app's answer (often an error) isn't read.
        #expect(
            try await backend.dialog(.cancel, Self.context, action: CardFixtures.submit, inputs: inputs) == .close(nil))
        let (cancel, body) = try sent(exchange)
        var expected = Dynamite_SubmitFormActionRequest.with { form in
            form.type = 2
            form.messageID = cancel.messageID
            form.appID = cancel.appID
        }
        expected.requestHeader = cancel.requestHeader
        #expect(body == Data(try expected.serializedBytes() as [UInt8]))
    }
    @Test func theAppsAnswersBecomeDialogSteps() {
        let ok = Dynamite_ActionStatus()
        #expect(DynamiteBackend.answer(setup: nil, status: ok, dialog: nil, message: "m") == .close(nil))
        #expect(
            DynamiteBackend.answer(setup: nil, status: .with { $0.message = "Started." }, dialog: nil, message: "m")
                == .close("Started."))
        #expect(
            DynamiteBackend.answer(
                setup: nil,
                status: .with {
                    $0.code = 3
                    $0.message = "Bad"
                }, dialog: CardFixtures.dialog, message: "m") == .invalid("Bad"))
        #expect(
            DynamiteBackend.answer(
                setup: .with {
                    $0.type = 1
                    $0.setupURL = "https://example.com/setup"
                }, status: ok, dialog: nil, message: "m")
                == .configure(URL(string: "https://example.com/setup")!))
        #expect(
            DynamiteBackend.answer(setup: .with { $0.setupURL = "javascript:x" }, status: ok, dialog: nil, message: "m")
                == .close(nil))
        // An app that wants its user signed in first answers with its page in place of a dialog.
        #expect(
            DynamiteBackend.answer(setup: nil, status: ok, dialog: nil, url: "https://example.com/signin", message: "m")
                == .configure(URL(string: "https://example.com/signin")!))
    }
    @Test func aSlashCommandsDialogIsInvoked() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_InvokeDialogResponse.with { $0.dialog = CardFixtures.dialog })
        ])
        let answer = try await backend.dialog(.open, Self.context, action: nil, inputs: [])
        let request = try #require(exchange.requests.last)
        #expect(request.url?.path == "/api/invoke_dialog")
        let sent = try Dynamite_InvokeDialogRequest(serializedBytes: Self.body(request))
        var expected = Dynamite_InvokeDialogRequest.with {
            $0.messageID = sent.messageID
            $0.appID = .with {
                $0.id = "bot"
                $0.type = .bot
            }
        }
        expected.requestHeader = sent.requestHeader
        #expect(Self.body(request) == Data(try expected.serializedBytes() as [UInt8]))
        if case .show(let dialog) = answer {
            #expect(dialog.title == "T")
        } else {
            Issue.record("no dialog: \(answer)")
        }
    }
}

/// The store's dialog: opened from a card's button, kept open with what's wrong, replaced by the next step, closed
/// with a note, and closing it tells the app.
@MainActor struct DialogStoreTests {
    private func opened() async throws -> (ChatStore, FakeBackend, ParleyDomain.Message) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.select("design")
        let message = try #require(store.history.messages.first { $0.attachments.first?.card?.by?.name == "Shipyard" })
        let card = try #require(message.attachments.first?.card)
        let create = try #require(card.links.first { $0.dialog == true }?.action)
        await store.clickCard(message, card: card.id, action: create, inputs: [])
        return (store, fake, message)
    }
    @Test func aDialogButtonOpensTheAppsDialog() async throws {
        let (store, fake, message) = try await opened()
        #expect(await fake.dialogSteps == ["open \(message.id) app=shipyard"])
        #expect(await fake.cardClicks.isEmpty)  // not a card click
        #expect(
            store.dialog?.dialog == FakeBackend.createIssue && store.dialog?.app == "Shipyard"
                && store.dialog?.conversation == "design")
    }
    @Test func submittingKeepsItOpenWhenWrongAndClosesWithANote() async throws {
        let (store, fake, message) = try await opened()
        let create = try #require(FakeBackend.createIssue.primary?.action)
        await store.submitDialog(action: create, inputs: [Card.Input(name: "title", value: " ")])
        #expect(store.dialog?.problem == "Give the issue a title.")
        await store.submitDialog(
            action: create,
            inputs: [Card.Input(name: "title", value: "Fix it"), Card.Input(name: "priority", value: "high")])
        #expect(await fake.dialogSteps.last == "submit \(message.id) app=shipyard title=Fix it priority=high")
        #expect(store.dialog == nil && store.toast == "Issue #43 created.")
        await eventually {
            store.history.messages.contains { $0.sender.id == "shipyard" && $0.text.hasSuffix("Fix it") }
        }  // through the stream
        #expect(store.history.messages.contains { $0.sender.id == "shipyard" && $0.text.hasSuffix("Fix it") })
    }
    @Test func theNextStepReplacesTheCardAndARefusalSaysWhoRefused() async throws {
        let (store, fake, _) = try await opened()
        let next = AppDialog(title: "Step 2", card: Card(sections: [[.text("Done?", [])]]))
        await fake.answerNextDialog(.show(next))
        await store.submitDialog(action: Data(), inputs: [])
        #expect(store.dialog?.dialog == next && store.dialog?.problem == nil)
        await fake.answerNextDialog(.invalid(""))
        await store.submitDialog(action: Data(), inputs: [])
        #expect(store.dialog?.problem == "Shipyard is unable to process your request.")
        await fake.simulateChangeFailure()
        await store.submitDialog(action: Data(), inputs: [])
        #expect(store.dialog != nil && store.dialog?.problem != nil && store.error == nil)  // said in the sheet
        var links: [URL] = []
        store.openURL = { links.append($0) }
        await fake.answerNextDialog(.configure(URL(string: "https://example.com/setup")!))
        await store.submitDialog(action: Data(), inputs: [])
        #expect(store.dialog == nil && links == [URL(string: "https://example.com/setup")!])
    }
    @Test func closingTellsTheApp() async throws {
        let (store, fake, message) = try await opened()
        await store.cancelDialog()
        let steps = await fake.dialogSteps
        #expect(store.dialog == nil && steps.last == "cancel \(message.id) app=shipyard")
        await store.cancelDialog()  // nothing open: nothing sent
        #expect(await fake.dialogSteps.count == 2)
    }
    @Test func aRefusedOpenIsAnError() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await fake.answerNextDialog(.invalid("Your administrator has disabled apps here"))
        await store.openDialog(
            DialogContext(message: "m", app: "a"), app: "App", in: "design", action: Data(), inputs: [])
        #expect(store.dialog == nil && store.error == "Your administrator has disabled apps here")
    }
}

/// The sheet hosted as the window hosts it, at the usual width and a narrow one: the card's inputs stay inside, and the
/// buttons sit in the footer, the primary one at the trailing edge.
@MainActor struct DialogSheetHostedTests {
    @Test(arguments: [DialogLayout.width, 420]) func theSheetKeepsItsCardAndButtonsInside(width: CGFloat) throws {
        let open = ChatStore.OpenDialog(
            context: DialogContext(message: "m", app: "a"), conversation: "c", app: "App",
            dialog: FakeBackend.createIssue, problem: "Give the issue a title.")
        let height = DialogLayout.height(open, width: width)
        let host = NSHostingView(rootView: DialogSheet(open: open, width: width))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width + 0.5 && abs(host.fittingSize.height - height) <= 1)
        #expect(height < DialogLayout.maxHeight)  // short enough to need no scrolling
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let fields = all(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(fields.count >= 1)
        for field in fields {
            let frame = field.convert(field.bounds, to: host)
            #expect(
                frame.minX >= DialogLayout.margin - 0.5 && frame.maxX <= width - DialogLayout.margin + 0.5, "\(frame)")
            #expect(frame.minY >= 0 && frame.maxY <= height, "\(frame)")
        }
    }
}
