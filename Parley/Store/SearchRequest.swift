import Foundation

/// Search asked for from outside the window (Shortcuts, Siri): the panel opens with these words.
struct SearchRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let query: String
}
