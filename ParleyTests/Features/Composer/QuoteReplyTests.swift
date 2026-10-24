import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

struct QuoteReplyMapperTests {
    @Test func messagesKeepTheirLastUpdateTimeForQuoting() throws {
        var proto = NetworkTests.message("m1", topic: "t1", at: 10)
        proto.lastUpdateTime = 25
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:])?.lastUpdateMicros == 25)
        proto.lastUpdateTime = 0
        proto.lastEditTime = 17  // older servers: the edit, else the create time
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:])?.lastUpdateMicros == 17)
        proto.lastEditTime = 0
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:])?.lastUpdateMicros == 10)
    }
    @Test func quoteTypeQuoteReplyIsOneOnTheWire() throws {
        let ref = try #require(
            try DynamiteMapper.quotedRef(
                QuotedMessage(sender: "Maria", text: "hi", id: "dm/a/t1/m1", lastUpdateMicros: 300)))
        #expect(ref.quoteType.rawValue == 1)
        let bytes: [UInt8] = try ref.serializedBytes()
        #expect(bytes.suffix(2) == [0x20, 0x01])  // field 4, varint 1
        #expect(bytes.contains(0x10) && ref.lastUpdateTime == 300)  // field 2, varint
        #expect(
            ref.messageID.messageID == "m1" && ref.messageID.parentID.topicID.topicID == "t1"
                && ref.messageID.parentID.topicID.groupID.dmID.dmID == "a")
        #expect(try DynamiteMapper.quotedRef(QuotedMessage(sender: "Maria", text: "hi")) == nil)  // a received snapshot names no message
    }
}

extension NetworkTests { @Suite struct QuoteReplyTests: NetworkSuite {} }

extension NetworkTests.QuoteReplyTests {
    @Test func quoteRepliesCarryTheQuotedMessageOnCreateTopicAndCreateMessage() async throws {
        let topic = try Self.proto(
            Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(
            Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, exchange) = try await Self.connected([topic, reply])
        let quote = QuotedMessage(
            sender: "Maria", text: "hello", id: "dm/a/t1/m1", lastUpdateMicros: 1_700_000_000_123_456)
        let sent = try await backend.send(
            MessageDraft(text: "yes", localID: "local-1", quoting: quote), to: "dm/a", thread: nil)
        _ = try await backend.send(
            MessageDraft(text: "yes", localID: "local-2", quoting: quote), to: "dm/a", thread: ThreadID(head: sent.id))
        let topics = try exchange.requests.filter { $0.url?.path == "/api/create_topic" }.map {
            try Dynamite_CreateTopicRequest(serializedBytes: Self.body($0))
        }
        let replies = try exchange.requests.filter { $0.url?.path == "/api/create_message" }.map {
            try Dynamite_CreateMessageRequest(serializedBytes: Self.body($0))
        }
        for info in [try #require(topics.first).messageInfo, try #require(replies.first).messageInfo] {
            #expect(info.hasQuotedMessage)
            #expect(info.quotedMessage.quoteType == .quoteReply)
            #expect(info.quotedMessage.lastUpdateTime == 1_700_000_000_123_456)
            #expect(
                info.quotedMessage.messageID.messageID == "m1"
                    && info.quotedMessage.messageID.parentID.topicID.topicID == "t1")
            #expect(!info.acceptFormatAnnotations)
        }
    }
    @Test func plainSendsCarryNoQuote() async throws {
        let topic = try Self.proto(
            Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([topic])
        _ = try await backend.send(MessageDraft(text: "plain", localID: "local-1"), to: "dm/a", thread: nil)
        let request = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(!request.messageInfo.hasQuotedMessage)
    }
}

@MainActor struct QuoteReplyStoreTests {
    @Test func quotingShowsInTheEchoIsSentAndThenCleared() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        var quoted = try #require(store.history.messages.first { $0.id == "d1" })
        quoted.lastUpdateMicros = 42
        store.quote(quoted)
        let scope = store.key("design", nil)
        #expect(
            store.drafting.quoting[scope]
                == QuotedMessage(sender: "Maria Chen", text: quoted.text, id: "d1", lastUpdateMicros: 42))
        store.setDraft("sure", conversation: "design", thread: nil)
        await fake.simulateSendFailure()  // keeps the local echo in the store
        await store.send(conversation: "design")
        let echo = try #require(store.history.messages.first { $0.delivery == .failed })
        #expect(echo.quote?.sender == "Maria Chen" && echo.quote?.text == quoted.text)
        let sent = await fake.sentDrafts.last?.quoting
        #expect(sent?.id == "d1" && sent?.lastUpdateMicros == 42)
        #expect(store.drafting.quoting[scope] == nil)
        await store.retry(echo)  // a retry quotes the same message
        #expect(await fake.sentDrafts.last?.quoting?.id == "d1")
        #expect(
            store.history.messages.contains {
                $0.text == "sure" && $0.quote?.sender == "Maria Chen" && $0.delivery == .sent
            })
    }
    @Test func aQuoteWithoutAServerUpdateTimeUsesTheCreateTime() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let quoted = try #require(store.history.messages.first { $0.id == "d1" })
        store.quote(quoted)
        #expect(
            store.drafting.quoting[store.key("design", nil)]?.lastUpdateMicros
                == Int64((quoted.createdAt.timeIntervalSince1970 * 1_000_000).rounded()))
    }
    @Test func quotingInAThreadStaysWithThatThread() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let head = try #require(store.history.messages.first { $0.id == "d4" })
        await store.openThread(head)
        let reply = try #require(store.history.messages.first { $0.id == "r1" })
        store.quote(reply)
        #expect(
            store.drafting.quoting[store.key("design", "d4")]?.id == "r1"
                && store.drafting.quoting[store.key("design", nil)] == nil)
        store.setDraft("agreed", conversation: "design", thread: "d4")
        await store.send(conversation: "design", thread: "d4")
        #expect(await fake.sentDrafts.last?.quoting?.id == "r1")
        #expect(store.timeline("design", thread: "d4").last?.quote?.sender == "Maria Chen")
        #expect(store.drafting.quoting.isEmpty)
    }
    @Test func pendingAndServiceMessagesCannotBeQuotedAndEditingTakesOver() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        var pending = try #require(store.history.messages.first { $0.id == "d1" })
        pending.delivery = .pending
        store.quote(pending)
        var service = try #require(store.history.messages.first { $0.id == "d1" })
        service.isSystem = true
        store.quote(service)
        #expect(store.drafting.quoting.isEmpty)
        store.quote(try #require(store.history.messages.first { $0.id == "d1" }))
        store.edit(try #require(store.history.messages.first { $0.id == "d3" }))  // editing my message drops the quote
        #expect(store.drafting.quoting.isEmpty && store.editingID("design", thread: nil) == "d3")
        store.quote(try #require(store.history.messages.first { $0.id == "d1" }))  // and quoting ends the edit
        #expect(store.editingID("design", thread: nil) == nil && store.drafting.text[store.key("design", nil)] == "")
    }
}

/// Seen live: quoting a photo with no text showed an empty quote block. Web Chat names the attachment instead.
@MainActor struct QuotedAttachmentTests {
    @Test func aQuoteOfATextlessMessageNamesItsAttachment() {
        func file(_ kind: ParleyDomain.Attachment.Kind, _ type: String, _ name: String = "x") -> ParleyDomain.Attachment
        { ParleyDomain.Attachment(name: name, contentType: type, kind: kind) }
        #expect(QuotedMessage.summary(text: "", attachments: [file(.image, "image/png")]) == "Photo")
        #expect(QuotedMessage.summary(text: "", attachments: [file(.image, "image/gif")]) == "GIF")
        #expect(QuotedMessage.summary(text: "", attachments: [file(.video, "video/mp4")]) == "Video")
        #expect(
            QuotedMessage.summary(text: "", attachments: [file(.file, "application/pdf", "plan.pdf")]) == "plan.pdf")
        #expect(QuotedMessage.summary(text: "hi", attachments: [file(.image, "image/png")]) == "hi")
        #expect(QuotedMessage.summary(text: "", attachments: []) == "")
    }
    @Test func quotingAPhotoFromTheComposerNamesIt() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let id = try #require(store.navigation.selectedID)
        let photo = Message.fixture(
            "", id: "p", in: id, attachments: [.fixture(.image, name: "image.png", contentType: "image/png")])
        store.quote(photo)
        #expect(store.drafting.quoting[store.key(id, nil)]?.text == "Photo")
        #expect(store.drafting.quoting[store.key(id, nil)]?.media?.name == "image.png")  // the composer shows its thumbnail, as Telegram does
    }
}

/// Clicking a quote goes to the message it quotes, as Telegram does.
@MainActor struct QuoteJumpTests {
    @Test func aReceivedQuoteKeepsTheQuotedMessagesID() throws {
        let proto = Dynamite_Message.with {
            $0.id.parentID.topicID.topicID = "t1"
            $0.id.messageID = "m2"
            $0.creator.userID.id = "u1"
            $0.textBody = "reply"
            $0.quotedMessageMetadata = .with {
                $0.messageID.parentID.topicID.topicID = "t0"
                $0.messageID.messageID = "m0"
                $0.textBody = "orig"
            }
        }
        let message = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:]))
        #expect(message.quote?.id == DynamiteID.message("dm/a", topic: "t0", message: "m0"))
    }
    @Test func showingALoadedQuotedMessageHighlightsIt() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 200))
        await store.start()
        await store.select("engineering")
        let loaded = try #require(store.timeline("engineering").first)
        await store.showQuoted(loaded.id, in: "engineering")
        #expect(store.history.highlightedID == loaded.id)
    }
    @Test func showingAnOlderQuotedMessageLoadsBackToIt() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 200))
        await store.start()
        await store.select("engineering")
        #expect(!store.timeline("engineering").contains { $0.id == "e5" })
        await store.showQuoted("e5", in: "engineering")
        #expect(store.timeline("engineering").contains { $0.id == "e5" } && store.history.highlightedID == "e5")
    }
}
