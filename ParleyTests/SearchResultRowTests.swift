import AppKit
import SwiftUI
import Testing
@testable import Parley

/// A search result as Google Chat's web draws it: the text, then what the message carries, so a picture or a file can be
/// told apart from the rest (ids and names made up).
@MainActor struct SearchResultRowTests {
    static let photo = Parley.Attachment(name: "Pasted image.png", contentType: "image/png", kind: .image, thumbnailURL: URL(string: "https://example.com/t"))
    static let doc = Parley.Attachment(name: "Launch plan", contentType: "application/vnd.google-apps.document", kind: .link,
                                url: URL(string: "https://docs.google.com/document/d/x/edit"))
    static let pdf = Parley.Attachment(name: "report.pdf", contentType: "application/pdf", kind: .file)
    static func message(_ text: String, _ attachments: [Parley.Attachment]) -> Message {
        Message(id: "space/x/t/m", conversationID: "space/x", sender: Person(id: "u1", name: "Maria"), text: text, createdAt: .now, attachments: attachments)
    }
    static func height(_ message: Message) -> CGFloat {
        let host = NSHostingView(rootView: SearchResultRow(message: message, conversation: "Design", load: { _, _ in Data() }).frame(width: 460))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// A message that is only a picture shows the picture, not an empty line.
    @Test func aPictureShowsItsThumbnail() {
        let textOnly = Self.height(Self.message("hello", []))
        #expect(Self.height(Self.message("", [Self.photo])) >= textOnly + SearchResultRow.thumbnail / 2)
    }
    /// Files and Drive links show by name with their kind's icon; cards and calls are not things to find.
    @Test func filesShowByName() {
        let call = Parley.Attachment(name: "Meet", kind: .call), card = Parley.Attachment(name: "Card", kind: .card)
        #expect(SearchResultRow.shown([Self.photo, Self.doc, call, card, Self.pdf]).map(\.name) == ["Pasted image.png", "Launch plan", "report.pdf"])
        #expect(SearchResultRow.symbol(Self.doc) == "doc.text")
        #expect(SearchResultRow.symbol(Self.pdf) == nil)   // a file: the Finder's icon for its type
        #expect(SearchResultRow.symbol(FakeBackend.demoVoice) == "waveform")
    }
}
