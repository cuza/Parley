import AppKit
import SwiftUI
import Testing
@testable import Parley

private func listed(_ uuid: String, _ shortcode: String, state: Dynamite_CustomEmoji.State = .enabled) -> Dynamite_CustomEmoji {
    .with { $0.uuid = uuid; $0.shortcode = shortcode; $0.state = state; $0.readToken = "rt-" + uuid; $0.blobID = "blob-" + uuid }
}

extension AuthTests {
    /// As Google Chat's web pages it: the first page with the filters; each later one with the previous answer's page token
    /// and the validation token (an answer's field 4, back as field 5), no filters. Without the validation token a
    /// workspace's second page answers HTTP 400.
    @Test func customEmojiListPagesWithThePageAndValidationTokens() async throws {
        let first = Dynamite_ListCustomEmojisResponse.with {
            $0.customEmojis = [listed("a", "parrot"), listed("b", "off", state: .systemDisabled)]; $0.nextPageToken = "p2"; $0.validationToken = "v1"
        }
        let second = Dynamite_ListCustomEmojisResponse.with { $0.customEmojis = [listed("c", "ship-it")]; $0.nextPageToken = "p3"; $0.validationToken = "v1" }
        let third = Dynamite_ListCustomEmojisResponse.with { $0.customEmojis = [listed("d", "tada"), listed("a", "parrot")]; $0.validationToken = "v1" }
        let (backend, exchange) = try await Self.connected([try Self.proto(first), try Self.proto(second), try Self.proto(third)])
        let emoji = try await backend.customEmojis()
        #expect(emoji.map(\.id) == ["a", "c", "d"])   // only enabled ones can be sent, each once
        #expect(try Dynamite_CustomEmoji(serializedBytes: emoji[0].payload) == listed("a", "parrot"))
        let requests = try exchange.requests.filter { $0.url?.path == "/api/list_custom_emojis" }
            .map { try Dynamite_ListCustomEmojisRequest(serializedBytes: Self.body($0)) }
        #expect(requests.count == 3 && requests.allSatisfy { $0.pageSize == 100 && $0.hasRequestHeader })
        #expect(requests[0].filters.count == 2 && !requests[0].hasPageToken && !requests[0].hasValidationToken)
        #expect(requests[0].filters[0].kind == 2 && requests[0].filters[0].states.states == [.enabled, .systemDisabled] && requests[0].filters[0].operation == 1)
        #expect(requests[0].filters[1].kind == 3 && requests[0].filters[1].states.states == [.enabled] && requests[0].filters[1].operation == 1)
        #expect(requests[1].filters.isEmpty && requests[1].pageToken == "p2" && requests[1].validationToken == "v1")
        #expect(requests[2].filters.isEmpty && requests[2].pageToken == "p3" && requests[2].validationToken == "v1")
        // Filter {1 kind, 2 {1 states}, 3 operation} on the wire.
        #expect(try Dynamite_ListCustomEmojisRequest.Filter(serializedBytes: Data([0x08, 0x03, 0x12, 0x02, 0x08, 0x01, 0x18, 0x01])) == DynamiteBackend.customEmojiFilters[1])
    }
    /// A page that fails after others loaded keeps what they brought: the picker shows those instead of none.
    @Test func aLaterPageFailingKeepsTheEarlierOnes() async throws {
        let first = Dynamite_ListCustomEmojisResponse.with { $0.customEmojis = [listed("a", "parrot")]; $0.nextPageToken = "p2"; $0.validationToken = "v1" }
        let (backend, _) = try await Self.connected([try Self.proto(first), StubExchange.Reply(status: 500)])
        #expect(try await backend.customEmojis().map(\.id) == ["a"])
    }
    /// The log line says what a read found in numbers and state names only: no shortcode, id, token or link.
    @Test func theListsLogLineCarriesNoNamesOrTokens() {
        var tally = CustomEmojiTally()
        tally.add([listed("uuid-secret", "secret-name"), listed("b", "other", state: .systemDisabled),
                   .with { $0.uuid = "c"; $0.shortcode = "no-token"; $0.state = .enabled }])
        let line = tally.line(end: "done")
        #expect(line == "custom emoji: 1 pages, 3 listed, 2 enabled, 1 enabled without an image, states [enabled: 2, systemDisabled: 1], done")
        for secret in ["uuid-secret", "secret-name", "rt-", "blob", "no-token", "http"] { #expect(!line.contains(secret)) }
        // Errors by kind and code, never their text.
        #expect(CustomEmojiTally.kind(of: AuthFailure.http(429)) == "HTTP 429")
        #expect(CustomEmojiTally.kind(of: AuthFailure.malformedProto) == "malformedProto")
        #expect(CustomEmojiTally.kind(of: AuthFailure.bootstrapRedirect("a name")) == "bootstrapRedirect")
        #expect(CustomEmojiTally.kind(of: URLError(.timedOut)) == "network -1001")
    }
    @Test func aCustomEmojiPickedForAReactionSendsItsWholePayload() async throws {
        let list = Dynamite_ListCustomEmojisResponse.with { $0.customEmojis = [listed("a", "parrot")] }
        let (backend, exchange) = try await Self.connected([try Self.proto(list), try Self.proto(Dynamite_UpdateReactionResponse())])
        let store = await ChatStore(backend: backend)
        await store.loadCustomEmoji()
        let parrot = try #require(await store.customEmoji.first)
        let message = Message(id: "space/x/t1/h1", conversationID: "space/x", sender: Person(id: "u1", name: "Maria"), text: "hi")
        await store.react(parrot.text, custom: parrot, to: message)
        let sent = try Dynamite_UpdateReactionRequest(serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/update_reaction" })))
        #expect(sent.emoji.customEmoji == listed("a", "parrot") && sent.option == .add)
    }
}

struct CustomEmojiAnnotationTests {
    private let parrot = DynamiteMapper.customEmoji(listed("a", "parrot"))!
    @Test func customEmojiBecomesAnAnnotationWithItsPayloadBesideMentionsAndBold() throws {
        // "hi 👍\u{FFFD} @Ana": 👍 is two UTF-16 units, so the emoji is at 5.
        let formatting = [TextStyleRange(style: .bold, start: 0, length: 2), TextStyleRange(style: .customEmoji(parrot), start: 5, length: 1),
                          TextStyleRange(style: .mention(userID: "u2"), start: 7, length: 4)]
        let annotations = DynamiteMapper.annotations(formatting)
        #expect(annotations.map(\.type) == [.formatData, .customEmoji, .userMention])
        let emoji = annotations[1]
        #expect(emoji.startIndex == 5 && emoji.length == 1)
        #expect(emoji.customEmojiMetadata.customEmoji == listed("a", "parrot"))
    }
    @Test func anEditedMessageKeepsItsCustomEmoji() {
        let (text, formatting) = DynamiteMapper.richText("a\u{FFFD}", [.with { $0.type = .customEmoji; $0.startIndex = 1; $0.length = 1; $0.customEmojiMetadata.customEmoji = listed("a", "parrot") }])
        #expect(text == "a\u{FFFD}")
        #expect(DynamiteMapper.annotations(formatting).first?.customEmojiMetadata.customEmoji == listed("a", "parrot"))
    }
    @Test func aShortcodeStoredWithColonsShowsThemOnce() {
        #expect(DynamiteMapper.customEmoji(listed("m", ":masabito:"))?.text == ":masabito:")
        #expect(DynamiteMapper.customEmoji(listed("m", "masabito"))?.text == ":masabito:")
    }
}

@MainActor struct CustomEmojiComposerTests {
    private let parrot = CustomEmoji(id: "a", shortcode: "parrot", imageURL: URL(string: "https://example.invalid/parrot"), payload: Data([1, 2]))
    private let party = CustomEmoji(id: "b", shortcode: "party-parrot", imageURL: URL(string: "https://example.invalid/party"))

    @Test func anInsertedEmojiIsAnAttachmentAndAU_FFFDInTheDraft() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("👍 ", [])
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertCustomEmoji(parrot, replacing: view.selectedRange())
        view.insertCustomEmoji(parrot, replacing: view.selectedRange())   // equal neighbours stay two emoji
        view.insertText("x", replacementRange: view.selectedRange())       // typed after it: plain text
        #expect(view.textStorage?.attribute(.attachment, at: 3, effectiveRange: nil) is NSTextAttachment)
        #expect(view.draftText == "👍 \u{FFFD}\u{FFFD}x")
        let expected = [TextStyleRange(style: .customEmoji(parrot), start: 3, length: 1), TextStyleRange(style: .customEmoji(parrot), start: 4, length: 1)]
        #expect(view.formatting == expected)
        // A saved draft loads back as the same emoji.
        let reloaded = ComposerTextView(usingTextLayoutManager: false)
        reloaded.load(view.draftText, view.formatting + [TextStyleRange(style: .bold, start: 5, length: 1)])
        #expect(reloaded.draftText == view.draftText)
        #expect(Set(reloaded.formatting) == Set(expected + [TextStyleRange(style: .bold, start: 5, length: 1)]))
        #expect(reloaded.textStorage?.attribute(.attachment, at: 4, effectiveRange: nil) is NSTextAttachment)
    }
    @Test func aColonQueryOffersShortcodes() {
        #expect(MentionQuery.find(in: "hi :sh", caret: 6, shortcode: true) == MentionQuery(range: NSRange(location: 3, length: 3), text: "sh", shortcode: true))
        #expect(MentionQuery.find(in: "at 10:30", caret: 8, shortcode: true) == nil)
        #expect(MentionQuery.find(in: "hi :", caret: 4, shortcode: true) == nil)
        #expect(MentionQuery.find(in: ":a b", caret: 4, shortcode: true) == nil)
        #expect(MentionQuery.nearest(in: "@ana :par", caret: 9)?.shortcode == true)
        #expect(MentionQuery.nearest(in: "@ana", caret: 4)?.shortcode == false)
        #expect(MentionQuery.filter([party, parrot], by: "PAR").map(\.id) == ["a", "b"])
        #expect(MentionQuery.filter([party, parrot], by: "ty").map(\.id) == ["b"])
    }
    @Test func typingAShortcodeAsksForTheListAndPickingInsertsTheEmoji() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        var asked = 0
        view.needCustomEmoji = { asked += 1 }
        view.customEmoji = [parrot, party]
        view.load("", [])
        view.insertText(":parr", replacementRange: view.selectedRange())
        #expect(asked == 1 && view.mentionQuery?.shortcode == true)
        view.insertCustomEmoji(parrot, replacing: view.mentionQuery!.range, space: true)
        #expect(view.draftText == "\u{FFFD} " && view.formatting == [TextStyleRange(style: .customEmoji(parrot), start: 0, length: 1)])
    }
    @Test func aDraftWithCustomEmojiSurvivesTheLaunchCache() async throws {
        let cache = LaunchCache(url: URL.temporaryDirectory.appending(path: "parley-cache-\(UUID().uuidString).json"))
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        let formatting = [TextStyleRange(style: .customEmoji(parrot), start: 3, length: 1)]
        store.setDraft("hi \u{FFFD}", formatting: formatting, conversation: "design", thread: nil)
        store.flush()
        let reopened = ChatStore(backend: FakeBackend(), cache: cache)
        #expect(reopened.drafts.values.contains("hi \u{FFFD}"))
        #expect(reopened.draftFormatting.values.contains(formatting))
    }
    @Test func theOrganisationsEmojiLoadOncePerSession() async {
        let store = ChatStore(backend: FakeBackend())
        await store.loadCustomEmoji()
        await store.loadCustomEmoji()
        #expect(store.customEmoji.map(\.shortcode) == ["ship-it", "lgtm", "party-parrot"])
    }
}

@MainActor struct ReactionCardTests {
    private let load: (Parley.Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }
    @Test func theCardShowsAfterTheDelayAndTakesTheNamesInPlace() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: false)
        let pill = NSView(frame: NSRect(x: 10, y: 10, width: 40, height: 20)), other = NSView(frame: .zero)
        window.contentView?.addSubview(pill)
        let card = ReactionCard()
        card.delay = .milliseconds(10)
        let thumbs = ReactionCardView(reaction: Reaction(emoji: "👍", people: ["me", "a"]), names: ChatStore.reactorsLine(names: [], count: 2), load: load)
        card.hover(pill, thumbs)
        #expect(!card.isShown)
        await eventually { card.isShown }
        #expect(card.isShown && card.content?.names == "2 people")
        var named = thumbs; named.names = "Alex and You"
        card.update(other, ReactionCardView(reaction: thumbs.reaction, names: "someone else", load: load))   // another pill's: ignored
        card.update(pill, named)
        #expect((card.panel?.contentView as? NSHostingView<ReactionCardView>)?.rootView.names == "Alex and You")
        card.hide(other)
        #expect(card.isShown)
        card.hide(pill)
        #expect(!card.isShown)
        #expect(card.panel?.ignoresMouseEvents == true)
    }
}

@MainActor struct StandardEmojiShortcodeTests {
    @Test func aColonQueryOffersStandardEmojiAfterCustomOnesAndInsertsThem() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.customEmoji = [CustomEmoji(id: "t", shortcode: "thumbs-party")]
        view.load("", [])
        view.insertText(":thumbs", replacementRange: view.selectedRange())
        let matches = view.mentionMatches
        #expect(matches.first == .emoji(CustomEmoji(id: "t", shortcode: "thumbs-party")))
        let thumbs = try #require(matches.first { if case .unicode(let e) = $0 { e.character == "👍" } else { false } })
        view.insert(thumbs, replacing: view.mentionQuery!.range)
        #expect(view.draftText == "👍 " && view.mentionQuery == nil)
    }
    @Test func oneLetterAfterAColonOffersNoStandardEmoji() {   // ":D" and "a:b" stay text, and Return still sends
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("", [])
        view.insertText(":D", replacementRange: view.selectedRange())
        #expect(view.mentionMatches.isEmpty)
    }
    @Test func aColonShortcodeFindsFacepalm() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("", [])
        view.insertText(":facepalm", replacementRange: view.selectedRange())
        #expect(view.mentionMatches.first == .unicode(EmojiCatalog.emoji("🤦")))
        #expect(view.mentionMatches.contains(.unicode(EmojiCatalog.emoji("🤦\u{200D}♂\u{FE0F}"))))
    }
}
