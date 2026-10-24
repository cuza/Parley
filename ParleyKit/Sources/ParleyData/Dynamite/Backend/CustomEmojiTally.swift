import Foundation
import ParleyDomain
import SwiftProtobuf

/// What a `list_custom_emojis` read found, in numbers and state names only, for the log: no shortcode, id, token or link.
struct CustomEmojiTally {
    private var pages = 0, listed = 0, enabled = 0, withoutImage = 0
    private var states: [String: Int] = [:]
    mutating func add(_ page: [Dynamite_CustomEmoji]) {
        pages += 1
        listed += page.count
        for emoji in page {
            states["\(emoji.state)", default: 0] += 1
            if emoji.state == .enabled {
                enabled += 1
                if emoji.readToken.isEmpty { withoutImage += 1 }
            }
        }
    }
    /// `kept`: the distinct enabled emoji the read ends with (pages can repeat one).
    func line(kept: Int, end: String) -> String {
        let states = self.states.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return
            "custom emoji: \(pages) pages, \(listed) listed, \(enabled) enabled, \(withoutImage) enabled without an image, \(kept) kept, states [\(states)], \(end)"
    }
    /// An error's kind and code, never its text (which can carry a link).
    static func kind(of error: Error) -> String {
        switch error {
        case let failure as AuthFailure:  // the case's name, without what it carries
            if case .http(let status) = failure {
                "HTTP \(status)"
            } else {
                String(String(describing: failure).prefix { $0 != "(" })
            }
        case DynamiteError.malformedReply: "malformedReply"
        case let failure as URLError: "network \(failure.code.rawValue)"
        case is SwiftProtobuf.BinaryDecodingError: "the answer didn't decode"
        default: "\(type(of: error))"
        }
    }
}
