import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Parley

/// Files dropped on the conversation: a file from Finder is used where it is; a promised one (Photos, a screenshot's
/// thumbnail) offers no file URL, only the file's data, and is received into a copy of Parley's own.
struct DroppedFileTests {
    private func file(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "DroppedFileTests-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png bytes".utf8).write(to: url)
        return url
    }
    private func load(_ provider: NSItemProvider) async throws -> DroppedFile {
        try await withCheckedThrowingContinuation { done in
            _ = provider.loadTransferable(type: DroppedFile.self) { done.resume(with: $0) }
        }
    }
    @Test func aFileFromFinderIsUsedWhereItIs() async throws {
        let original = try file("Finder.png")
        let provider = try #require(NSItemProvider(contentsOf: original))
        let dropped = try await load(provider)
        #expect(dropped.url.standardizedFileURL == original.standardizedFileURL)
    }
    @Test func aPromisedFileIsReceivedIntoACopy() async throws {
        let source = try file("Photo.png")
        let provider = NSItemProvider()  // as Photos offers it: the file's type, no file URL
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(source, false, nil)
            return nil
        }
        let dropped = try await load(provider)
        #expect(dropped.url != source)
        #expect(try Data(contentsOf: dropped.url) == Data("png bytes".utf8))
    }
}
