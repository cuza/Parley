import Foundation

/// A service's answer for the @ list, with the query it answers: shown as the server ranked it for that query, and
/// narrowed by `narrow` while the answer for a newer query is on its way.
public struct Found<Item: Hashable & Sendable>: Hashable, Sendable {
    public var query = ""
    public var items: [Item] = []
    public init(query: String = "", items: [Item] = []) {
        self.query = query
        self.items = items
    }
    public func matching(_ query: String, limit: Int, narrow: ([Item]) -> [Item]) -> [Item] {
        Array((query == self.query ? items : narrow(items)).prefix(limit))
    }
}
