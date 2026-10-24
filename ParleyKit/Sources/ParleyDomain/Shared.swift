import Foundation

/// What Send to Parley brings in, from the Services menu or the share sheet: text and files. Once a conversation is
/// picked they join its draft, to be sent like anything typed there.
public struct Shared: Identifiable, Equatable {
    public let id = UUID()
    public var text: String
    public var files: [URL]
    public init(text: String, files: [URL]) {
        self.text = text
        self.files = files
    }
    public static func == (lhs: Shared, rhs: Shared) -> Bool { lhs.text == rhs.text && lhs.files == rhs.files }
}
