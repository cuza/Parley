import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

struct MapperTests: MapperFixtures {
    @Test func conversationIDsRoundTrip() throws {
        let dm = Dynamite_GroupId.with { $0.dmID.dmID = "abc" }
        let space = Dynamite_GroupId.with { $0.spaceID.spaceID = "xyz" }
        #expect(DynamiteID.conversation(dm) == "dm/abc")
        #expect(DynamiteID.conversation(space) == "space/xyz")
        #expect(try DynamiteID.group("dm/abc") == dm)
        #expect(try DynamiteID.group("space/xyz") == space)
        #expect(DynamiteID.conversation(Dynamite_GroupId()) == nil)
        #expect(throws: DynamiteError.badID) { try DynamiteID.group("maria") }  // FakeBackend-style IDs are rejected
        #expect(throws: DynamiteError.badID) { try DynamiteID.group("dm/") }
    }
    @Test func messageIDCarriesTopic() throws {
        let id = DynamiteID.message("space/xyz", topic: "t1", message: "m1")
        #expect(id == "space/xyz/t1/m1")
        #expect(try DynamiteID.topic(of: id) == "t1")
        #expect(throws: DynamiteError.badID) { try DynamiteID.topic(of: "local-123") }
    }
    @Test func messageMapsFieldsAndResolvesSender() throws {
        var proto = msg("m1", at: 1_700_000_000_000_000, text: "Hello")
        proto.lastEditTime = 1
        let message = try #require(DynamiteMapper.message(proto, in: "dm/abc", selfID: "me", people: people))
        #expect(message.id == "dm/abc/t1/m1")
        #expect(message.sender.name == "Maria")
        #expect(message.text == "Hello")
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(message.edited)
        #expect(message.delivery == .sent)
    }
    @Test func unknownSenderFallsBackToProtoNameThenUnknown() throws {
        var named = msg("m1", by: "u9")
        named.creator.name = "Sam"
        #expect(DynamiteMapper.message(named, in: "dm/a", selfID: "me", people: [:])?.sender.name == "Sam")
        #expect(
            DynamiteMapper.message(msg("m2", by: "u9"), in: "dm/a", selfID: "me", people: [:])?.sender.name == "Unknown"
        )
    }
    @Test func messagesWithoutTextGetPlaceholder() {
        #expect(
            DynamiteMapper.message(msg("m1", text: ""), in: "dm/a", selfID: "me", people: people)?.text
                == "Unsupported message")
    }
    @Test func deletedMessagesAreSkipped() {
        var deleted = msg("m1")
        deleted.deleteTime = 5
        #expect(DynamiteMapper.message(deleted, in: "dm/a", selfID: "me", people: people) == nil)
    }
    @Test func reactionsKeepCountAndOwnFlagAndDropCustomEmoji() throws {
        var proto = msg("m1")
        proto.reactions = [
            .with {
                $0.emoji.unicode = "👍"
                $0.count = 3
                $0.currentUserReacted = true
            },
            .with {
                $0.emoji.unicode = "🎉"
                $0.count = 1
            },
            .with { $0.count = 2 },  // custom emoji: no unicode
        ]
        let reactions = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: people)).reactions
        #expect(reactions.map(\.emoji) == ["👍", "🎉"])
        #expect(reactions[0].people.count == 3 && reactions[0].people.contains("me"))
        #expect(reactions[1].people.count == 1 && !reactions[1].people.contains("me"))
    }
    @Test func topicHeadCarriesReplyCountAndRepliesPointAtHead() {
        let topic = Dynamite_Topic.with { $0.replies = [msg("r2", at: 3), msg("head", at: 1), msg("r1", at: 2)] }
        let messages = DynamiteMapper.topic(topic, in: "space/x", selfID: "me", people: people)
        #expect(messages.map(\.id) == ["space/x/t1/head", "space/x/t1/r1", "space/x/t1/r2"])
        #expect(messages[0].threadID == nil && messages[0].replyCount == 2)
        #expect(messages.dropFirst().allSatisfy { $0.threadID == "space/x/t1/head" })
    }
    @Test func topicWithoutRepliesYieldsNothingAndSingleMessageIsHead() {
        #expect(DynamiteMapper.topic(Dynamite_Topic(), in: "dm/a", selfID: "me", people: people).isEmpty)
        let single = DynamiteMapper.topic(.with { $0.replies = [msg("m1")] }, in: "dm/a", selfID: "me", people: people)
        #expect(single.count == 1 && single[0].threadID == nil && single[0].replyCount == 0)
    }
    @Test func conversationKindsAndNames() throws {
        let space = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "Design"
            $0.readState.unreadMessageCount = 4
            $0.readState.starred = true
        }
        let dm = Dynamite_WorldItemLite.with {
            $0.groupID.dmID.dmID = "d"
            $0.dmMembers.members = [.with { $0.id = "me" }, .with { $0.id = "u1" }]
        }
        let groupDM = Dynamite_WorldItemLite.with {
            $0.groupID.dmID.dmID = "g"
            $0.dmMembers.members = ["me", "u1", "u2"].map { id in .with { $0.id = id } }
        }
        let unnamedRoom = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "r"
            $0.nameUsers.users = ["u2", "u1"].map { id in .with { $0.id = id } }
        }

        let spaceChat = try #require(DynamiteMapper.conversation(space, selfID: "me", people: people))
        #expect(
            (spaceChat.id, spaceChat.name, spaceChat.kind, spaceChat.unread, spaceChat.pinned) == (
                "space/s", "Design", .space, 4, true
            ))
        let direct = try #require(DynamiteMapper.conversation(dm, selfID: "me", people: people))
        #expect((direct.name, direct.kind) == ("Maria", .direct))
        let group = try #require(DynamiteMapper.conversation(groupDM, selfID: "me", people: people))
        #expect((group.name, group.kind) == ("Alex, Maria", .group))
        // A group DM someone named: a space-style id and a room name, still a group DM by its attribute (captured live).
        let namedGroupDM = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "n"
            $0.roomName = "Test Group"
            $0.attributes = [
                .with {
                    $0.type = 6
                    $0.value = "GROUP_DM"
                }
            ]
        }
        let named = try #require(DynamiteMapper.conversation(namedGroupDM, selfID: "me", people: people))
        #expect((named.name, named.kind) == ("Test Group", .group))
        let room = try #require(DynamiteMapper.conversation(unnamedRoom, selfID: "me", people: people))
        #expect((room.name, room.kind) == ("Alex, Maria", .group))
        #expect(DynamiteMapper.memberIDs(groupDM) == ["me", "u1", "u2"])
        #expect(DynamiteMapper.conversation(Dynamite_WorldItemLite(), selfID: "me", people: people) == nil)
    }
    /// A DM with an app: Google Chat's group type says so (2 a bot DM, 11 Ask Gemini's session DM), and the app's member id is a BOT.
    @Test func appDMsAreToldApartFromPeopleDMs() throws {
        func dm(_ type: Int32?, bot: Bool = false) -> Dynamite_WorldItemLite {
            .with {
                $0.groupID.dmID.dmID = "d"
                $0.dmMembers.members = [
                    .with { $0.id = "me" },
                    .with {
                        $0.id = "u1"
                        if bot { $0.type = .bot }
                    },
                ]
                if let type { $0.groupType = type }
            }
        }
        let human = try #require(DynamiteMapper.conversation(dm(6), selfID: "me", people: people))
        #expect((human.kind, human.app) == (.direct, nil))
        let app = try #require(DynamiteMapper.conversation(dm(2, bot: true), selfID: "me", people: people))
        #expect((app.kind, app.app) == (.direct, .bot))
        let gemini = try #require(DynamiteMapper.conversation(dm(11, bot: true), selfID: "me", people: people))
        #expect((gemini.kind, gemini.app) == (.direct, .gemini))
        #expect(DynamiteMapper.conversation(dm(nil, bot: true), selfID: "me", people: people)?.app == .bot)  // no group type: the BOT member
        let space = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "Design"
            $0.groupType = 4
        }
        #expect(DynamiteMapper.conversation(space, selfID: "me", people: people)?.app == nil)
    }
    @Test func conversationsCachedBeforeAppDMsStillDecode() throws {
        let old = #"{"id":"dm/d","name":"Maria","kind":"direct","members":[],"unread":0,"pinned":false,"muted":false}"#
        let room = try JSONDecoder().decode(Conversation.self, from: Data(old.utf8))
        #expect((room.kind, room.app) == (.direct, nil))
    }
    @Test func unreadComesFromReadTimesWhenNoCount() {
        #expect(
            DynamiteMapper.unread(
                .with {
                    $0.lastReadTime = 10
                    $0.lastHeadMessageCreateTime = 20
                }) == 1)
        #expect(
            DynamiteMapper.unread(
                .with {
                    $0.lastReadTime = 20
                    $0.lastHeadMessageCreateTime = 20
                }) == 0)
        #expect(
            DynamiteMapper.unread(
                .with {
                    $0.lastReadTime = 30
                    $0.lastHeadMessageCreateTime = 20
                    $0.markAsUnreadTimestamp = 25
                }) == 1)
        #expect(
            DynamiteMapper.unread(
                .with {
                    $0.lastReadTime = 1
                    $0.lastHeadMessageCreateTime = 2
                    $0.unreadSubscribedTopicCount = 3
                }) == 3)
        #expect(DynamiteMapper.unread(.with { $0.unreadMessageCount = 4 }) == 4)
        let item = Dynamite_WorldItemLite.with {
            $0.groupID.dmID.dmID = "a"
            $0.readState.lastHeadMessageCreateTime = 5
        }
        #expect(DynamiteMapper.conversation(item, selfID: "me", people: people)?.unread == 1)
    }
    @Test func messageIDsLookLikeGoogleChats() {
        let ids = (0..<50).map { DynamiteID.messageID(for: "local-\(UUID())-\($0)") }
        #expect(
            ids.allSatisfy { $0.count == 11 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } })
        #expect(Set(ids).count == 50)
    }
    @Test func domainMessageIDConvertsToProto() throws {
        let proto = try DynamiteID.protoMessageID("space/x/t1/m1")
        #expect(
            proto.messageID == "m1" && proto.parentID.topicID.topicID == "t1"
                && proto.parentID.topicID.groupID.spaceID.spaceID == "x")
        #expect(throws: DynamiteError.badID) { try DynamiteID.protoMessageID("local-1") }
    }

    @Test func threadCountComesFromTopicSummaryNotThePage() {
        let topic = Dynamite_Topic.with {
            $0.replies = [msg("t1", topic: "t1", at: 1), msg("r1", topic: "t1", at: 2), msg("r2", topic: "t1", at: 3)]
            $0.topicReadState.replySummary.totalReplyCount = 41
        }
        #expect(DynamiteMapper.topic(topic, in: "space/x", selfID: "me", people: people)[0].replyCount == 41)
        let counted = Dynamite_Topic.with {
            $0.replies = [msg("t1", topic: "t1", at: 1)]
            $0.topicReadState.messageCount = 5
        }
        #expect(DynamiteMapper.topic(counted, in: "space/x", selfID: "me", people: people)[0].replyCount == 4)
    }

}

struct AttachmentModelTests {
    @Test func cachedMessagesWithoutAttachmentsStillDecode() throws {
        let old =
            #"{"id":"m1","conversationID":"c","sender":{"id":"u","name":"U","presence":"offline"},"text":"hi","createdAt":0,"edited":false,"reactions":[],"delivery":"sent","replyCount":0}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(old.utf8))
        #expect(message.text == "hi" && message.attachments.isEmpty && message.threadID == nil)
        var withFile = message
        withFile.attachments = [
            Attachment(
                name: "a.pdf", contentType: "application/pdf", kind: .file,
                url: URL(string: "https://chat.google.com/x"))
        ]
        #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(withFile)) == withFile)
    }
}

/// FORMAT_DATA ranges in UTF-16 units; HIDDEN covers the literal markers.
struct FormattingTests {
    private let people = ["u1": Person(id: "u1", name: "Maria"), "u2": Person(id: "u2", name: "Alex")]
    private func format(_ type: Dynamite_FormatMetadata.FormatType, _ start: Int32, _ length: Int32)
        -> Dynamite_Annotation
    {
        .with {
            $0.type = .formatData
            $0.startIndex = start
            $0.length = length
            $0.formatMetadata.formatType = type
        }
    }
    private func map(
        _ text: String, _ annotations: [Dynamite_Annotation], quoted: Dynamite_QuotedMessageMetadata? = nil
    ) throws -> Message {
        let proto = Dynamite_Message.with {
            $0.id.parentID.topicID.topicID = "t1"
            $0.id.messageID = "m1"
            $0.creator.userID.id = "u1"
            $0.textBody = text
            $0.annotations = annotations
            if let quoted { $0.quotedMessageMetadata = quoted }
        }
        return try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: people))
    }

    @Test func hiddenMarkersAreRemovedAndStylesShift() throws {
        let message = try map("*hi* there", [format(.hidden, 0, 1), format(.bold, 1, 2), format(.hidden, 3, 1)])
        #expect(message.text == "hi there")
        #expect(message.formatting == [TextStyleRange(style: .bold, start: 0, length: 2)])
    }
    @Test func offsetsCountUTF16Units() throws {
        // 😀 is two UTF-16 units.
        let message = try map(
            "😀 _x_ `y`",
            [
                format(.hidden, 3, 1), format(.italic, 4, 1), format(.hidden, 5, 1),
                format(.hidden, 7, 1), format(.monospace, 8, 1), format(.hidden, 9, 1),
            ])
        #expect(message.text == "😀 x y")
        #expect(
            message.formatting == [
                TextStyleRange(style: .italic, start: 3, length: 1), TextStyleRange(style: .code, start: 5, length: 1),
            ])
    }
    @Test func outOfBoundsRangesAreSkipped() throws {
        let message = try map(
            "short", [format(.bold, 0, 99), format(.hidden, 3, 9), format(.strike, -1, 2), format(.underline, 0, 5)])
        #expect(message.text == "short")
        #expect(message.formatting == [TextStyleRange(style: .underline, start: 0, length: 5)])
    }
    @Test func blockStylesMentionsAndLinks() throws {
        let link = Dynamite_Annotation.with {
            $0.type = .url
            $0.startIndex = 22
            $0.length = 4
            $0.urlMetadata.url.url = "https://e.com"
        }
        let mention = Dynamite_Annotation.with {
            $0.type = .userMention
            $0.startIndex = 0
            $0.length = 5
            $0.userMentionMetadata.id.id = "u2"
        }
        let message = try map(
            "@Alex\n* item\n> quoted site",
            [
                mention, format(.hidden, 6, 2), format(.bulletedListItem, 6, 6), format(.hidden, 13, 2),
                format(.quoteBlock, 13, 13),
                format(.heading, 0, 5), format(.monospaceBlock, 0, 1), format(.strike, 1, 1), link,
            ])
        #expect(message.text == "@Alex\nitem\nquoted site")
        #expect(
            Set(message.formatting) == [
                TextStyleRange(style: .mention(userID: "u2"), start: 0, length: 5),
                TextStyleRange(style: .listItem, start: 6, length: 4),
                TextStyleRange(style: .quote, start: 11, length: 11),
                TextStyleRange(style: .heading, start: 0, length: 5),
                TextStyleRange(style: .codeBlock, start: 0, length: 1),
                TextStyleRange(style: .strike, start: 1, length: 1),
                TextStyleRange(style: .link(URL(string: "https://e.com")!), start: 18, length: 4),
            ])
        #expect(message.attachments.isEmpty)  // no image_url: Google Chat shows only the inline link, no card
    }
    @Test func structuredQuoteReplacesTheFallbackLine() throws {
        let quoted = Dynamite_QuotedMessageMetadata.with {
            $0.creator.userID.id = "u2"
            $0.textBody = "*orig*"
            $0.annotations = [format(.hidden, 0, 1), format(.bold, 1, 4), format(.hidden, 5, 1)]
        }
        let message = try map(
            "↪ _Alex: orig_\nreply *now*",
            [format(.italic, 3, 10), format(.hidden, 21, 1), format(.bold, 22, 3), format(.hidden, 25, 1)],
            quoted: quoted)
        #expect(message.quote == QuotedMessage(sender: "Alex", text: "orig"))
        #expect(message.text == "reply now")
        #expect(message.formatting == [TextStyleRange(style: .bold, start: 6, length: 3)])
        // Without field 37 the fallback text is all there is: leave it.
        let plain = try map("↪ _Alex: orig_\nreply", [])
        #expect(plain.text == "↪ _Alex: orig_\nreply" && plain.quote == nil)
    }
    @Test func aQuotedPhotoWithoutTextIsNamedPhoto() throws {
        let quoted = Dynamite_QuotedMessageMetadata.with {
            $0.creator.userID.id = "u2"
            $0.annotations = [
                .with { annotation in
                    annotation.type = .uploadMetadata
                    annotation.uploadMetadata = .with {
                        $0.attachmentToken = "t"
                        $0.contentType = "image/png"
                        $0.contentName = "image.png"
                    }
                }
            ]
        }
        #expect(try map("Google deberia pagarme", [], quoted: quoted).quote?.text == "Photo")
    }
    @Test func cachedMessagesWithoutFormattingStillDecode() throws {
        let old =
            #"{"id":"m1","conversationID":"c","sender":{"id":"u","name":"U","presence":"offline"},"text":"hi","createdAt":0,"edited":false,"#
            + #""reactions":[],"delivery":"sent","replyCount":0,"attachments":[]}"#
        var message = try JSONDecoder().decode(Message.self, from: Data(old.utf8))
        #expect(message.formatting.isEmpty && message.quote == nil)
        message.formatting = [
            TextStyleRange(style: .link(URL(string: "https://e.com")!), start: 0, length: 2),
            TextStyleRange(style: .bold, start: 0, length: 1),
        ]
        message.quote = QuotedMessage(sender: "Alex", text: "orig")
        #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)) == message)
    }
}

/// profile images, space icons and link-preview cards.
struct AvatarAndPreviewTests {
    @Test func personCarriesItsAvatarAndSchemeRelativeURLsGetHTTPS() {
        let user = Dynamite_User.with {
            $0.userID.id = "u1"
            $0.name = "Maria"
            $0.avatarURL = "//lh3.googleusercontent.com/a/xyz=s96-c"
        }
        #expect(
            DynamiteMapper.person(user)
                == Person(
                    id: "u1", name: "Maria", avatarURL: URL(string: "https://lh3.googleusercontent.com/a/xyz=s96-c")))
        #expect(DynamiteMapper.person(.with { $0.userID.id = "u2" }) == Person(id: "u2", name: "Unknown"))
        #expect(DynamiteMapper.imageURL("http://e.com/a.png") == nil)  // https only
        #expect(DynamiteMapper.imageURL("") == nil)
    }
    @Test func unresolvedSenderKeepsTheCreatorsAvatar() throws {
        let proto = Dynamite_Message.with {
            $0.id.parentID.topicID.topicID = "t"
            $0.id.messageID = "m"
            $0.textBody = "hi"
            $0.creator.userID.id = "x"
            $0.creator.name = "Sam"
            $0.creator.avatarURL = "https://lh3.googleusercontent.com/a/s"
        }
        let message = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:]))
        #expect(message.sender.avatarURL == URL(string: "https://lh3.googleusercontent.com/a/s"))
    }
    @Test func spacesGetEmojiAndImageAndDirectMessagesTheOtherPersonsPhoto() throws {
        let face = URL(string: "https://lh3.googleusercontent.com/a/maria")
        let people = ["me": Person(id: "me", name: "Dave"), "u1": Person(id: "u1", name: "Maria", avatarURL: face)]
        let space = Dynamite_WorldItemLite.with {
            $0.groupID.spaceID.spaceID = "s"
            $0.roomName = "Design"
            $0.avatarInfo.emoji.unicode = "🚀"
            $0.avatarURL = "//lh3.googleusercontent.com/room"
        }
        let spaceChat = try #require(DynamiteMapper.conversation(space, selfID: "me", people: people))
        #expect(spaceChat.emoji == "🚀" && spaceChat.avatarURL == URL(string: "https://lh3.googleusercontent.com/room"))
        let dm = Dynamite_WorldItemLite.with {
            $0.groupID.dmID.dmID = "d"
            $0.dmMembers.members = ["me", "u1"].map { id in .with { $0.id = id } }
        }
        let direct = try #require(DynamiteMapper.conversation(dm, selfID: "me", people: people))
        #expect(direct.emoji == nil && direct.avatarURL == face)
    }
    @Test func previewsFollowGoogleChatsRenderRules() throws {
        func link(_ edit: (inout Dynamite_UrlMetadata) -> Void) -> Dynamite_Annotation {
            .with {
                $0.type = .url
                $0.urlMetadata.url.url = "https://example.com/a"
                edit(&$0.urlMetadata)
            }
        }
        let card = link {
            $0.snippet = "About us"
            $0.domain = "Example.com"
            $0.imageURL = "//example.com/og.png"
        }
        let image = link {
            $0.mimeType = "image/png"
            $0.imageURL = "https://lh3.googleusercontent.com/p"
        }
        let hidden = link {
            $0.shouldNotRender = true
            $0.title = "x"
            $0.imageURL = "https://e.com/i.png"
        }
        let forced = Dynamite_Annotation.with {
            $0.chipRenderType = .render
            $0.urlMetadata = hidden.urlMetadata
        }
        let doNot = Dynamite_Annotation.with {
            $0.chipRenderType = .doNotRender
            $0.urlMetadata = card.urlMetadata
        }
        let richText = link {
            $0.urlSource = .richText
            $0.title = "x"
            $0.imageURL = "https://e.com/i.png"
        }
        let noImage = link { $0.title = "Plain" }
        let inline = Dynamite_Annotation.with {
            $0.inlineRenderFormat = 1
            $0.urlMetadata = card.urlMetadata
        }

        #expect(
            DynamiteMapper.attachment(card)
                == Attachment(
                    name: "About us", kind: .link, thumbnailURL: URL(string: "https://example.com/og.png"),
                    url: URL(string: "https://example.com/a"), snippet: "About us", domain: "example.com"))
        #expect(DynamiteMapper.attachment(image)?.kind == .image)
        #expect(DynamiteMapper.attachment(image)?.thumbnailURL == URL(string: "https://lh3.googleusercontent.com/p"))
        // An image link Google sent no image for shows no card, as in Google Chat: Parley never loads a sender's own server.
        let bare = link { $0.mimeType = "image/png" }
        #expect(DynamiteMapper.attachment(bare) == nil)
        #expect(DynamiteMapper.inlinesImages(URL(string: "https://media.giphy.com/media/x/giphy.gif")!))
        #expect(!DynamiteMapper.inlinesImages(URL(string: "https://giphy.com.evil.example/x.gif")!))
        #expect(!DynamiteMapper.inlinesImages(URL(string: "http://static2.klipy.com/x.gif")!))
        #expect(DynamiteMapper.attachment(forced)?.name == "x")  // an explicit chip_render_type overrides should_not_render
        for skipped in [hidden, doNot, richText, noImage, inline] { #expect(DynamiteMapper.attachment(skipped) == nil) }
    }
    @Test func fifeURLsAskForTheDisplaySize() throws {
        let fife = try #require(URL(string: "https://lh3.googleusercontent.com/a/xyz=s96-c"))
        #expect(RemoteImage.sized(fife, px: 64) == URL(string: "https://lh3.googleusercontent.com/a/xyz=s64-c"))
        #expect(
            RemoteImage.sized(try #require(URL(string: "https://yt3.ggpht.com/abc")), px: 40)
                == URL(string: "https://yt3.ggpht.com/abc=s40-c"))
        let other = try #require(URL(string: "https://example.com/a=b"))
        #expect(RemoteImage.sized(other, px: 64) == other)
    }
    @Test func cachesWrittenBeforeAvatarsAndPreviewsStillDecode() throws {
        let person = try JSONDecoder().decode(
            Person.self, from: Data(#"{"id":"u","name":"U","presence":"offline"}"#.utf8))
        #expect(person.avatarURL == nil)
        let room = try JSONDecoder().decode(
            Conversation.self,
            from: Data(
                #"{"id":"c","name":"C","kind":"space","members":[],"unread":0,"pinned":false,"muted":false}"#.utf8))
        #expect(room.emoji == nil && room.avatarURL == nil)
        let link = try JSONDecoder().decode(
            Attachment.self, from: Data(#"{"name":"n","contentType":"","kind":"link"}"#.utf8))
        #expect(link.snippet == nil && link.domain == nil)
        var full = room
        full.emoji = "🚀"
        full.avatarURL = URL(string: "https://lh3.googleusercontent.com/r")
        #expect(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(full)) == full)
    }
}
