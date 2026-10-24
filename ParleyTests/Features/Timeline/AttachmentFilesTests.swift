import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct AttachmentFilesTests {
    static let image = Attachment(
        name: "cat.png", contentType: "image/png", kind: .image, url: URL(string: "https://chat.google.com/a?token=1"))
    static let file = Attachment(
        name: "notes.txt", contentType: "text/plain", kind: .file, url: URL(string: "https://chat.google.com/a?token=2")
    )
    static let link = Attachment(
        name: "Example", kind: .link, url: URL(string: "https://example.com"), domain: "example.com")
    let folder = FileManager.default.temporaryDirectory.appending(path: "AttachmentFilesTests-\(UUID().uuidString)")

    /// A store whose loads are counted.
    final class Loads { var count = 0 }
    func files(_ loads: Loads = Loads(), bytes: Data = Data("bytes".utf8)) -> AttachmentFiles {
        AttachmentFiles(folder: folder) { _, thumbnail in
            #expect(!thumbnail)
            loads.count += 1
            return bytes
        }
    }

    // MARK: Cache
    @Test func fileNamesAreSanitized() {
        #expect(AttachmentFiles.fileName(Attachment(name: "a/b:c.pdf", kind: .file)) == "a-b-c.pdf")
        #expect(AttachmentFiles.fileName(Attachment(name: "..hidden.txt", kind: .file)) == "hidden.txt")
        #expect(
            AttachmentFiles.fileName(Attachment(name: "  ", contentType: "image/png", kind: .image)) == "attachment.png"
        )
        #expect(
            AttachmentFiles.fileName(Attachment(name: "photo", contentType: "image/jpeg", kind: .image)) == "photo.jpeg"
        )
        #expect(AttachmentFiles.fileName(Attachment(name: "report", kind: .file)) == "report")
    }
    @Test func eachAttachmentHasItsOwnFolderUnderTheCache() {
        let files = files()
        let cached = files.cacheURL(Self.image)
        var other = Self.image
        other.url = URL(string: "https://chat.google.com/a?token=9")
        #expect(cached.lastPathComponent == "cat.png")
        #expect(cached.path.hasPrefix(folder.path))
        #expect(cached == files.cacheURL(Self.image))
        #expect(cached != files.cacheURL(other))
    }
    @Test func aDownloadIsWrittenOnceAndReused() async throws {
        let loads = Loads()
        let files = files(loads)
        #expect(files.cachedFile(Self.file) == nil)
        let url = try await files.file(Self.file)
        #expect(try Data(contentsOf: url) == Data("bytes".utf8))
        #expect(try await files.file(Self.file) == url)
        #expect(loads.count == 1)
        #expect(files.cachedFile(Self.file) == url)
    }
    @Test func anUnsentFileIsUsedWhereItIs() async throws {
        let loads = Loads()
        let files = files(loads)
        let local = Attachment(name: "draft.txt", kind: .file, url: URL(filePath: "/tmp/draft.txt"))
        #expect(try await files.file(local) == URL(filePath: "/tmp/draft.txt"))
        #expect(loads.count == 0)
    }
    @Test func savingNeverOverwrites() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(AttachmentFiles.unusedURL("a.txt", in: folder) == folder.appending(path: "a.txt"))
        try Data().write(to: folder.appending(path: "a.txt"))
        #expect(AttachmentFiles.unusedURL("a.txt", in: folder) == folder.appending(path: "a 2.txt"))
        try Data().write(to: folder.appending(path: "a 2.txt"))
        #expect(AttachmentFiles.unusedURL("a.txt", in: folder) == folder.appending(path: "a 3.txt"))
    }
    @Test func saveCopiesIntoTheFolderAndRemembersWhere() async throws {
        let files = files()
        let report = Attachment(
            name: "report.txt", kind: .file, url: URL(string: "https://chat.google.com/a?token=\(UUID())"))  // `saved` is shared
        let target = try await files.save(report, in: folder.appending(path: "Downloads"))
        #expect(target.lastPathComponent == "report.txt")
        #expect(try Data(contentsOf: target) == Data("bytes".utf8))
        #expect(AttachmentFiles.saved[report] == target)
    }

    /// A file from a chat is from the internet: saved, it carries the quarantine flag, so Gatekeeper checks an app or
    /// script someone sent before it first opens, as with a browser download.
    @Test func aSavedFileIsQuarantined() async throws {
        let files = files()
        let tool = Attachment(
            name: "tool.command", kind: .file, url: URL(string: "https://chat.google.com/a?token=\(UUID())"))
        let target = try await files.save(tool, in: folder.appending(path: "Downloads"))
        let quarantine = try target.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        #expect(
            try await files.file(tool).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)  // the cached copy too
    }

    // MARK: Quick Look
    @Test func previewGoesThroughTheConversationsFilesAndMediaButNotLinks() {
        let files = files()
        let message = RowFixtures.row("x") { $0.attachments = [Self.image, Self.link] }.message
        let later = RowFixtures.row("y") { $0.attachments = [Self.file] }.message
        files.messages = { [message, later] }
        #expect(files.preparePreview(Self.file))
        #expect(files.previewItems.map(\.attachment) == [Self.image, Self.file])
        #expect(files.previewIndex == 1)
        #expect(files.previewItems[1].previewItemTitle == "notes.txt")
        #expect(!files.preparePreview(Self.link))
    }
    @Test func aPreviewItemPointsAtItsCachedFile() async throws {
        let files = files()
        files.messages = { [RowFixtures.row("x") { $0.attachments = [Self.file] }.message] }
        #expect(files.preparePreview(Self.file))
        #expect(files.previewItems[0].previewItemURL == nil)
        try await files.fetch(files.previewItems[0])
        #expect(files.previewItems[0].previewItemURL == files.cacheURL(Self.file))
    }

    // MARK: Menu
    @Test func menuOffersQuickLookSaveAndCopy() {
        let files = files()
        #expect(
            files.menuItems(Self.image).map(\.title) == [
                "Quick Look", "Save to Downloads", "Save As…", "Copy Image", "Share…",
            ])
        #expect(
            files.menuItems(Self.file).map(\.title) == [
                "Quick Look", "Save to Downloads", "Save As…", "Copy File", "Share…",
            ])
        #expect(files.menuItems(Self.link).isEmpty)
    }
    /// Share… hands over a downloaded file as it is, and otherwise one that downloads when a service asks for it, so
    /// the menu opens at once.
    @Test func shareHandsOverTheFile() async throws {
        let files = files()
        let waiting = try #require(files.shareItem(Self.file) as? NSItemProvider)
        #expect(waiting.suggestedName == "notes.txt")
        let type = try #require(waiting.registeredContentTypes.first)
        let delivered: Data = try await withCheckedThrowingContinuation { finished in
            _ = waiting.loadFileRepresentation(for: type) { url, _, error in
                if let url, let data = try? Data(contentsOf: url) {
                    finished.resume(returning: data)
                } else {
                    finished.resume(throwing: error ?? CancellationError())
                }
            }
        }
        let file = try await files.file(Self.file)
        #expect(delivered == (try Data(contentsOf: file)))
        #expect(files.shareItem(Self.file) as? URL == file)
    }
    @Test func menuOffersShowInFinderOnceSaved() throws {
        let files = files()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = folder.appending(path: "notes.txt")
        try Data().write(to: saved)
        let report = Attachment(
            name: "report.txt", kind: .file, url: URL(string: "https://chat.google.com/a?token=\(UUID())"))  // `saved` is shared
        AttachmentFiles.saved[report] = saved
        #expect(files.menuItems(report).map(\.title).last == "Show in Finder")
    }
    @Test func rowMenuAddsTheAttachmentItemsAfterTheReactions() {
        let row = RowFixtures.row("x") { $0.attachments = [Self.file] }
        let view = MessageRowView()
        var actions = MessageRowActions()
        actions.files = files()
        view.configure(row, own: false, kind: .space, meID: "me", actions: actions)
        let titles = view.contextMenu(attachment: Self.file).items.map(\.title)
        #expect(Array(titles.dropFirst(2).prefix(2)) == ["Quick Look", "Save to Downloads"])
        #expect(titles.contains("Reply in Thread"))
        #expect(!view.contextMenu().items.map(\.title).contains("Quick Look"))
    }

    // MARK: Copy and drag
    @Test func copyPutsTheFileAndAnImagesBytesOnThePasteboard() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cat.png")
        try Data("png".utf8).write(to: url)
        let item = AttachmentFiles.pasteboardItem(file: url, attachment: Self.image)
        #expect(item.string(forType: .fileURL) == url.absoluteString)
        #expect(item.data(forType: .png) == Data("png".utf8))
        let fileItem = AttachmentFiles.pasteboardItem(file: url, attachment: Self.file)
        #expect(fileItem.types == [.fileURL])
    }
    @Test func dragPromisesTheFileAndOffersItsURLOnceCached() async throws {
        let files = files()
        let promise = files.dragWriter(Self.file)
        #expect(promise.fileType == "public.plain-text")
        #expect(files.filePromiseProvider(promise, fileNameForType: promise.fileType) == "notes.txt")
        #expect(!promise.writableTypes(for: .general).contains(.fileURL))
        let cached = try await files.file(Self.file)
        let ready = files.dragWriter(Self.file)
        #expect(ready.writableTypes(for: .general).contains(.fileURL))
        #expect(ready.pasteboardPropertyList(forType: .fileURL) as? String == cached.absoluteString)
    }
    @Test func aPromiseWritesTheDownloadedFile() async throws {
        let files = files()
        let destination = folder.appending(path: "drop/notes.txt")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let error: Error? = await withCheckedContinuation { done in
            files.filePromiseProvider(files.dragWriter(Self.file), writePromiseTo: destination) {
                done.resume(returning: $0)
            }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: destination) == Data("bytes".utf8))
    }
}
