import Foundation
import Testing
@testable import Parley

/// Search filters in search_messages_v2's filter (request field 3), in the shapes the server reads.
extension AuthTests {
    private static func searched(_ filters: SearchFilters, query: String = "test") async throws -> Dynamite_SearchMessagesV2Request {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_SearchMessagesV2Response())])
        _ = try await backend.searchMessages(query, filters: filters, cursor: nil)
        return try Dynamite_SearchMessagesV2Request(serializedBytes: Self.body(exchange, "search_messages_v2"))
    }
    /// From {2: [{1: id}]}, a date range {4: {1 start µs, 2 end µs}}, has {5: [{1: annotation type}]}, a link {7: true},
    /// mentions me {6: [{1: [{1: my id}]}]}; none needs a sort.
    @Test func filtersGoWhereTheServerReadsThem() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000), end = Date(timeIntervalSince1970: 1_791_000_000)
        let request = try await Self.searched(SearchFilters(from: [Person(id: "u1", name: "Maria")], after: start, before: end,
                                                            has: [.image, .pdf, .link], mentionsMe: true))
        let filter: [UInt8] = try request.filter.serializedBytes()
        #expect(filter == Wire.ld(2, Wire.str(1, "u1"))
                + Wire.ld(4, Wire.int(1, 1_790_000_000_000_000) + Wire.int(2, 1_791_000_000_000_000))
                + Wire.ld(5, Wire.int(1, 9)) + Wire.ld(5, Wire.int(1, 10))
                + Wire.ld(6, Wire.ld(1, Wire.str(1, "me")))
                + Wire.int(7, 1))
        #expect(!request.hasSort)
    }
    /// "Older than a week": only the end of the range.
    @Test func anOpenRangeSendsOnlyItsEnd() async throws {
        let end = Date(timeIntervalSince1970: 1_791_000_000)
        let request = try await Self.searched(SearchFilters(before: end))
        #expect(try request.filter.serializedBytes() as [UInt8] == Wire.ld(4, Wire.int(2, 1_791_000_000_000_000)))
    }
    @Test func filtersCombineWithAConversation() async throws {
        let request = try await Self.searched(SearchFilters(saidIn: ["space/x"], has: [.file]))
        #expect(request.filter.has.map(\.type) == [.driveFile] && request.filter.scope.conversations.count == 1 && request.sort.operator == .relevance)
    }
    /// Said in: one {1 GroupId, 2: 1} per conversation in field 8.4, with the sort Google needs for a scope.
    @Test func saidInScopesToEveryPickedConversation() async throws {
        let request = try await Self.searched(SearchFilters(saidIn: ["space/x", "dm/y"]))
        #expect(try request.filter.scope.conversations.map { try $0.groupID.serializedBytes() as [UInt8] }
                == [Wire.ld(1, Wire.str(1, "x")), Wire.ld(3, Wire.str(1, "y"))])
        #expect(request.filter.scope.conversations.allSatisfy { $0.kind == 1 } && request.sort.operator == .relevance)
    }
}

struct SearchFilterChoiceTests {
    /// Any file covers every file kind, so picking it drops them, and picking a kind drops it, as Google Chat's chips do.
    @Test func anyFileExcludesTheKinds() {
        var filters = SearchFilters(has: [.image, .pdf, .link])
        filters.toggle(.file)
        #expect(filters.has == [.file, .link])
        filters.toggle(.document)
        #expect(filters.has == [.document, .link])
    }
    @Test func olderThanCountsBackFromNow() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(SearchFilters.Age.week.before(now: now) == now.addingTimeInterval(-7 * 86_400))
        #expect(SearchFilters.Age.year.before(now: now) == now.addingTimeInterval(-365 * 86_400))
    }
}

@MainActor
struct SearchFilterStoreTests {
    @Test func filtersAloneSearch() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let maria = try #require(store.conversations.flatMap(\.members).first { $0.name.hasPrefix("Maria") })
        await store.search("", filters: SearchFilters(from: [maria]))
        #expect(!store.searchResults.isEmpty && store.searchResults.allSatisfy { $0.sender.id == maria.id })
        await store.search("", filters: SearchFilters())
        #expect(store.searchResults.isEmpty)   // nothing asked
    }
    @Test func saidInKeepsToThoseConversations() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.search("", filters: SearchFilters(saidIn: ["maria", "alex"]))
        #expect(!store.searchResults.isEmpty && Set(store.searchResults.map(\.conversationID)) == ["maria", "alex"])
    }
}
