import AppKit
import UniformTypeIdentifiers

/// The share sheet's Parley: it shows nothing of its own. What was shared goes on a pasteboard named for this hand-off,
/// and a parley://share link opens Parley, which asks for the conversation and puts it into that draft.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handOff() }
    }
    private func handOff() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var texts: [String] = [], files: [URL] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if let url = await Self.url(provider, .fileURL) { files.append(url) }
                else if let url = await Self.url(provider, .url) { texts.append(url.absoluteString) }
                else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                        let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { texts.append(text) }
                else if let file = await Self.file(provider) { files.append(file) }
            }
            if texts.isEmpty, files.isEmpty, let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
        }
        let name = "dev.cuza.Parley.share.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: .init(name))
        pasteboard.clearContents()
        if !files.isEmpty { pasteboard.writeObjects(files as [NSURL]) } else { pasteboard.setString(texts.joined(separator: "\n"), forType: .string) }
        let scheme = Bundle.main.object(forInfoDictionaryKey: "ParleyURLScheme") as? String ?? "parley"
        if let link = URL(string: "\(scheme)://share?pasteboard=\(name)") { NSWorkspace.shared.open(link) }
        extensionContext?.completeRequest(returningItems: nil)
    }
    private static func url(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier),
              let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { return nil }
        if let url = item as? URL { return url.isFileURL == (type == .fileURL) ? url : nil }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
    /// A photo or other data with no file of its own: written into this extension's temporary folder, which Parley copies from.
    private static func file(_ provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredTypeIdentifiers.first else { return nil }
        return await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return done.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/\(provider.suggestedName.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent)")
                do {
                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    done.resume(returning: copy)
                } catch { done.resume(returning: nil) }
            }
        }
    }
}
