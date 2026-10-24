import AppKit

/// What the share extension and the app agree on for a hand-off. This file is built into both targets.
enum ShareHandOff {
    /// Words shared along with files go on a pasteboard type of their own: with files, a pasteboard's plain text is their names.
    static let textType = NSPasteboard.PasteboardType("dev.cuza.Parley.shared-text")
    /// Each hand-off's pasteboard is named with this prefix, then a unique suffix.
    static let pasteboardPrefix = "dev.cuza.Parley.share"
}
