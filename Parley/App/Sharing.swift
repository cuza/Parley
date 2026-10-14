import AppKit

/// What Send to Parley brings in, from the Services menu or the share sheet: text and files. Once a conversation is
/// picked they join its draft, to be sent like anything typed there.
struct Shared: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var files: [URL]
    init(text: String, files: [URL]) { self.text = text; self.files = files }
    /// Files when the pasteboard has any, else its text; nil when it has neither.
    init?(_ pasteboard: NSPasteboard) {
        files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        text = files.isEmpty ? pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        if text.isEmpty && files.isEmpty { return nil }
    }
    /// The share sheet's hand-off, `parley://share?pasteboard=<name>`: the extension's pasteboard, read once and freed.
    /// Files inside an app container (photos and data the extension wrote) are copied out first, since the extension's
    /// container is cleaned up on its own schedule; files shared from Finder stay where they are.
    init?(link: URL) {
        guard link.scheme?.hasPrefix("parley") == true, link.host() == "share",
              let name = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pasteboard" })?.value,
              name.hasPrefix("dev.cuza.Parley.share") else { return nil }
        let pasteboard = NSPasteboard(name: .init(name))
        defer { pasteboard.releaseGlobally() }
        guard let shared = Shared(pasteboard) else { return nil }
        text = shared.text
        files = shared.files.map(Self.ownCopy)
    }
    private static func ownCopy(_ url: URL) -> URL {
        guard url.path.contains("/Containers/") else { return url }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
        let copy = folder.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch { return url }
    }
    static func == (a: Shared, b: Shared) -> Bool { a.text == b.text && a.files == b.files }
}

/// Services ▸ Send to Parley (`NSServices` in the Info.plist names `sendToParley`).
@MainActor final class ShareService: NSObject {
    var received: ((Shared) -> Void)?
    @objc func sendToParley(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let shared = Shared(pasteboard) else { error.pointee = "There's nothing to send to Parley."; return }
        NSApp.activate()
        received?(shared)
    }
}
