import Foundation
import Testing

@testable import ParleyDomain

@Test(arguments: [("png", "image/png"), ("jpg", "image/jpeg"), ("pdf", "application/pdf"), ("txt", "text/plain")])
func mimeTypeForCommonExtensions(ext: String, mime: String) {
    #expect(FileTypes.mimeType(forExtension: ext) == mime)
}

@Test func unknownExtensionHasNoMimeType() {
    #expect(FileTypes.mimeType(forExtension: "qqq") == nil)
}

@Test func localImageIsAnImage() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "parleykit-\(UUID().uuidString).png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try Attachment.localFile(at: url)
    #expect(file.contentType == "image/png")
    #expect(file.kind == .image)
}
