import AppKit
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// A custom emoji as Google Chat lists it.
func listedEmoji(_ uuid: String, _ shortcode: String, state: Dynamite_CustomEmoji.State = .enabled)
    -> Dynamite_CustomEmoji
{
    .with {
        $0.uuid = uuid
        $0.shortcode = shortcode
        $0.state = state
        $0.readToken = "rt-" + uuid
        $0.blobID = "blob-" + uuid
    }
}

extension NetworkTests { @Suite struct CustomEmojiSendTests: NetworkSuite {} }

extension NetworkTests.CustomEmojiSendTests {
    /// As Google Chat's web pages it: the first page with the filters; each later one with the previous answer's page token
    /// and the validation token (an answer's field 4, back as field 5), no filters. Without the validation token a
    /// workspace's second page answers HTTP 400.
    @Test func customEmojiListPagesWithThePageAndValidationTokens() async throws {
        let first = Dynamite_ListCustomEmojisResponse.with {
            $0.customEmojis = [listedEmoji("a", "parrot"), listedEmoji("b", "off", state: .systemDisabled)]
            $0.nextPageToken = "p2"
            $0.validationToken = "v1"
        }
        let second = Dynamite_ListCustomEmojisResponse.with {
            $0.customEmojis = [listedEmoji("c", "ship-it")]
            $0.nextPageToken = "p3"
            $0.validationToken = "v1"
        }
        let third = Dynamite_ListCustomEmojisResponse.with {
            $0.customEmojis = [listedEmoji("d", "tada"), listedEmoji("a", "parrot")]
            $0.validationToken = "v1"
        }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(first), try Self.proto(second), try Self.proto(third),
        ])
        let emoji = try await backend.customEmojis()
        #expect(emoji.map(\.id) == ["a", "c", "d"])  // only enabled ones can be sent, each once
        #expect(try Dynamite_CustomEmoji(serializedBytes: emoji[0].payload) == listedEmoji("a", "parrot"))
        let requests = try exchange.requests.filter { $0.url?.path == "/api/list_custom_emojis" }
            .map { try Dynamite_ListCustomEmojisRequest(serializedBytes: Self.body($0)) }
        #expect(requests.count == 3 && requests.allSatisfy { $0.pageSize == 100 && $0.hasRequestHeader })
        #expect(requests[0].filters.count == 2 && !requests[0].hasPageToken && !requests[0].hasValidationToken)
        #expect(
            requests[0].filters[0].kind == 2 && requests[0].filters[0].states.states == [.enabled, .systemDisabled]
                && requests[0].filters[0].operation == 1)
        #expect(
            requests[0].filters[1].kind == 3 && requests[0].filters[1].states.states == [.enabled]
                && requests[0].filters[1].operation == 1)
        #expect(requests[1].filters.isEmpty && requests[1].pageToken == "p2" && requests[1].validationToken == "v1")
        #expect(requests[2].filters.isEmpty && requests[2].pageToken == "p3" && requests[2].validationToken == "v1")
        // Filter {1 kind, 2 {1 states}, 3 operation} on the wire.
        #expect(
            try Dynamite_ListCustomEmojisRequest.Filter(
                serializedBytes: Data([0x08, 0x03, 0x12, 0x02, 0x08, 0x01, 0x18, 0x01]))
                == DynamiteBackend.customEmojiFilters[1])
    }
    /// A page that brings nothing new ends the read: a server handing out pages that repeat can't keep it going.
    @Test func aPageWithNothingNewEndsTheList() async throws {
        let first = Dynamite_ListCustomEmojisResponse.with {
            $0.customEmojis = [listedEmoji("a", "parrot")]
            $0.nextPageToken = "p2"
            $0.validationToken = "v1"
        }
        let again = Dynamite_ListCustomEmojisResponse.with {
            $0.customEmojis = [listedEmoji("a", "parrot")]
            $0.nextPageToken = "p3"
            $0.validationToken = "v1"
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(first), try Self.proto(again)])
        #expect(try await backend.customEmojis().map(\.id) == ["a"])
        #expect(exchange.requests.filter { $0.url?.path == "/api/list_custom_emojis" }.count == 2)
    }
    /// A page that fails after others loaded keeps what they brought: the picker shows those instead of none.
    @Test func aLaterPageFailingKeepsTheEarlierOnes() async throws {
        let first = Dynamite_ListCustomEmojisResponse.with {
            $0.customEmojis = [listedEmoji("a", "parrot")]
            $0.nextPageToken = "p2"
            $0.validationToken = "v1"
        }
        let (backend, _) = try await Self.connected([try Self.proto(first), StubExchange.Reply(status: 500)])
        #expect(try await backend.customEmojis().map(\.id) == ["a"])
    }
    /// The log line says what a read found in numbers and state names only: no shortcode, id, token or link.
    @Test func theListsLogLineCarriesNoNamesOrTokens() {
        var tally = CustomEmojiTally()
        tally.add([
            listedEmoji("uuid-secret", "secret-name"), listedEmoji("b", "other", state: .systemDisabled),
            .with {
                $0.uuid = "c"
                $0.shortcode = "no-token"
                $0.state = .enabled
            },
        ])
        let line = tally.line(kept: 2, end: "done")
        #expect(
            line
                == "custom emoji: 1 pages, 3 listed, 2 enabled, 1 enabled without an image, 2 kept, states [enabled: 2, systemDisabled: 1], done"
        )
        for secret in ["uuid-secret", "secret-name", "rt-", "blob", "no-token", "http"] {
            #expect(!line.contains(secret))
        }
        // Errors by kind and code, never their text.
        #expect(CustomEmojiTally.kind(of: AuthFailure.http(429)) == "HTTP 429")
        #expect(CustomEmojiTally.kind(of: AuthFailure.malformedProto) == "malformedProto")
        #expect(CustomEmojiTally.kind(of: DynamiteError.malformedReply) == "malformedReply")
        #expect(CustomEmojiTally.kind(of: AuthFailure.bootstrapRedirect("a name")) == "bootstrapRedirect")
        #expect(CustomEmojiTally.kind(of: URLError(.timedOut)) == "network -1001")
    }
    /// ":" plus letters searches the server, as Google Chat's web does: search_emojis_v2 {1 ":query", 2 [CUSTOM], 3 40}.
    /// Its custom results become CustomEmoji; standard ones are left to the local catalog.
    @Test func aShortcodeSearchAsksTheServerForCustomEmoji() async throws {
        let found = Dynamite_SearchEmojisResponse.with {
            $0.results = [
                .with { $0.customEmoji = listedEmoji("z", "samba") }, .with { $0.unicode = Data([0x0A, 0x01, 0x41]) },
            ]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(found)])
        #expect(try await backend.searchCustomEmoji(matching: "sam").map(\.id) == ["z"])
        let sent = try Dynamite_SearchEmojisRequest(
            serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/search_emojis_v2" }))
        )
        #expect(sent.query == ":sam" && sent.types == [.custom] && sent.limit == 40 && sent.hasRequestHeader)
    }
    @Test func aCustomEmojiPickedForAReactionSendsItsWholePayload() async throws {
        let list = Dynamite_ListCustomEmojisResponse.with { $0.customEmojis = [listedEmoji("a", "parrot")] }
        let (backend, exchange) = try await Self.connected([
            try Self.proto(list), try Self.proto(Dynamite_UpdateReactionResponse()),
        ])
        let store = await ChatStore(backend: backend)
        await store.loadCustomEmoji()
        let parrot = try #require(await store.lookups.customEmoji.first)
        let message = Message.fixture("hi", id: "space/x/t1/h1", from: .fixture("u1", name: "Maria"), in: "space/x")
        await store.react(parrot.text, custom: parrot, to: message)
        let sent = try Dynamite_UpdateReactionRequest(
            serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/update_reaction" })))
        #expect(sent.emoji.customEmoji == listedEmoji("a", "parrot") && sent.option == .add)
    }
}
