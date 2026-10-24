import Foundation
import SwiftProtobuf
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Editing, deleting and reacting to a message: what each request sends and what the timeline gets back.
extension NetworkTests { @Suite struct MessageEditingTests: NetworkSuite {} }

extension NetworkTests.MessageEditingTests {
    @Test func editReplacesTextAndKeepsThread() async throws {
        var edited = Self.message("h1", topic: "t1", at: 1, by: "me")
        edited.textBody = "new"
        edited.lastEditTime = 2
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })
        ])
        try await backend.edit("space/x/t1/h1", text: "new")
        #expect(exchange.requests.last?.url?.path == "/api/edit_message")
        let message = Self.upserts(await Self.drain(backend)).last
        #expect(message?.id == "space/x/t1/h1" && message?.text == "new" && message?.edited == true)
    }
    /// An edit replaces what it doesn't send: a reply's quote goes back with the new text, or the reply loses it.
    @Test func editKeepsAReplysQuote() async throws {
        var reply = Self.message("h1", topic: "t1", at: 3, by: "me")
        reply.quotedMessageMetadata = .with { quote in
            quote.messageID = .with {
                $0.messageID = "q1"
                $0.parentID.topicID.topicID = "t0"
            }
            quote.lastUpdateTimeWhenQuoted = 1234
            quote.textBody = "the original"
        }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_EditMessageResponse.with { $0.message = reply })
        ])
        await backend.handle(Self.pushed(.messagePosted, reply))
        try await backend.edit("space/x/t1/h1", text: "new")
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.messageInfo.quotedMessage.messageID.messageID == "q1")
        #expect(request.messageInfo.quotedMessage.messageID.parentID.topicID.topicID == "t0")
        #expect(request.messageInfo.quotedMessage.lastUpdateTime == 1234)
        #expect(request.messageInfo.quotedMessage.quoteType == .quoteReply)
    }
    @Test func deleteEmitsRemoval() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_DeleteMessageResponse())])
        try await backend.deleteMessage("dm/a/t1/m1")
        #expect(exchange.requests.last?.url?.path == "/api/delete_message")
        #expect(await Self.drain(backend).contains(.messageDeleted("dm/a/t1/m1")))
    }
    @Test func reactionTogglesOwnReactionOnLoadedMessage() async throws {
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_UpdateReactionResponse()), try Self.proto(Dynamite_UpdateReactionResponse()),
        ])
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        try await backend.setReaction("👍", custom: nil, for: "space/x/t1/h1", present: true)
        try await backend.setReaction("👍", custom: nil, for: "space/x/t1/h1", present: false)
        #expect(exchange.requests.filter { $0.url?.path == "/api/update_reaction" }.count == 2)
        let reactions = Self.upserts(await Self.drain(backend)).map(\.reactions)
        #expect(reactions == [[], [Reaction(emoji: "👍", people: ["me"])], []])
    }
    @Test func reactionOnUnknownMessageStillSendsRPC() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateReactionResponse())])
        try await backend.setReaction("🎉", custom: nil, for: "dm/a/t9/m9", present: true)
        #expect(exchange.requests.last?.url?.path == "/api/update_reaction")
        #expect(Self.upserts(await Self.drain(backend)).isEmpty)
    }
}

extension NetworkTests.MessageEditingTests {
    /// Google Chat edits only the text: the message's uploads and Drive files go back unchanged, or the server drops them.
    @Test func editKeepsTheMessagesAttachments() async throws {
        let upload = Dynamite_Annotation.with {
            $0.type = .uploadMetadata
            $0.uploadMetadata.attachmentToken = "tok"
            $0.uploadMetadata.contentType = "image/png"
        }
        let drive = Dynamite_Annotation.with {
            $0.type = .driveFile
            $0.driveMetadata.id = "d1"
            $0.driveMetadata.title = "Plan"
        }
        let bold = Dynamite_Annotation.with {
            $0.type = .formatData
            $0.startIndex = 0
            $0.length = 5
            $0.formatMetadata.formatType = .bold
        }
        let link = Dynamite_Annotation.with {
            $0.type = .url
            $0.startIndex = 6
            $0.length = 5
            $0.urlMetadata.url.url = "https://world.example"
        }
        var original = Self.message("h1", topic: "t1", at: 1, by: "me")
        original.textBody = "hello world"
        original.annotations = [bold, upload, link, drive]
        var edited = original
        edited.textBody = "hello there"
        edited.lastEditTime = 2
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })
        ])
        await backend.handle(Self.pushed(.messagePosted, original))
        try await backend.edit(
            "space/x/t1/h1", text: "hello there", formatting: [TextStyleRange(style: .italic, start: 6, length: 5)])
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.textBody == "hello there")
        #expect(
            request.annotations == DynamiteMapper.annotations([TextStyleRange(style: .italic, start: 6, length: 5)]) + [
                upload, drive,
            ])
        #expect(request.messageInfo.acceptFormatAnnotations)
    }
    /// A link the message already has comes back into the composer as a link: it goes back as its own annotation, once;
    /// a link added while editing goes as a new one.
    @Test func editSendsAnExistingLinkOnceAndANewOne() async throws {
        let old = Dynamite_Annotation.with {
            $0.type = .url
            $0.startIndex = 0
            $0.length = 5
            $0.urlMetadata.url.url = "https://hello.example"
        }
        var original = Self.message("h1", topic: "t1", at: 1, by: "me")
        original.textBody = "hello world"
        original.annotations = [old]
        var edited = original
        edited.lastEditTime = 2
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })
        ])
        await backend.handle(Self.pushed(.messagePosted, original))
        let added = URL(string: "https://world.example")!
        try await backend.edit(
            "space/x/t1/h1", text: "hello world",
            formatting: [
                TextStyleRange(style: .link(URL(string: "https://hello.example")!), start: 0, length: 5),
                TextStyleRange(style: .link(added), start: 6, length: 5),
            ])
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.annotations == [DynamiteMapper.link(added, 6, 5), old])
    }
    @Test func editOfAnUnloadedMessageSendsOnlyItsText() async throws {
        var edited = Self.message("h1", topic: "t1", at: 1, by: "me")
        edited.textBody = "new"
        let (backend, exchange) = try await Self.connected([
            try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })
        ])
        try await backend.edit("space/x/t1/h1", text: "new")
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(
            request.textBody == "new" && request.annotations.isEmpty && !request.messageInfo.acceptFormatAnnotations)
    }
}
