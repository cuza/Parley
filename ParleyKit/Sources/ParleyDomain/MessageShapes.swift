import Foundation
import Synchronization

/// An anonymous record of the messages Parley doesn't fully draw (see `MessageCoverage`), which a user can export from
/// Settings and send: each message's protobuf field tree, read from its wire bytes, with no values.
/// A skeleton names field numbers and nesting; `N:v` is a varint, `N:f32`/`N:f64` a fixed number, `N:Lk` a run of k
/// bytes (text, ids, links), `N{…}` a nested message, `×k` k equal repeats. Varints keep their value (`N=v`) only at
/// `enumPaths`. Kept in memory for the launch.
public enum MessageShapes {
    public struct Entry: Codable, Hashable, Sendable {
        var fields: [String]  // the gaps `MessageCoverage` found, e.g. "15.7.2.2.13.?6", "19.1=9"
        var skeleton: String  // the first such message's whole tree
        public var count = 1  // messages seen with this gap
        public init(fields: [String], skeleton: String, count: Int = 1) {
            self.fields = fields
            self.skeleton = skeleton
            self.count = count
        }
    }
    public static let cap = 200

    /// The gaps seen this launch, at most `cap` of them, each with its first message's tree.
    public struct Store: Sendable {
        public var entries: [Entry] = []
        public var index: [String: Int] = [:]  // entry by its gap
    }
    public static let shared = Mutex(Store())

    /// One line per gap, the most seen first: "15.7.2.2.13.?6 — 3 messages".
    public static func summary(_ entries: [Entry]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries { for field in entry.fields { counts[field, default: 0] += entry.count } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) — \($0.value) message\($0.value == 1 ? "" : "s")" }
    }

    public static func export(_ entries: [Entry], app: String, os: String, date: Date) -> Data {
        struct File: Encodable {
            var app: String
            var macOS: String
            var date: Date
            var summary: [String]
            var entries: [Entry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(File(app: app, macOS: os, date: date, summary: summary(entries), entries: entries)))
            ?? Data()
    }
}
