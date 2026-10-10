import AppKit
import SwiftUI
import Testing
@testable import Parley

/// The thread pane's header shows the thread's first message: for one with no text, what it carried
/// ("Photo", the file's name, "Voice message"…) beside its picture, never an empty block.
@MainActor struct ThreadHeaderTests {
    private func texts(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(texts) }

    @Test func aPhotoOnlyFirstMessageShowsPhotoInTheHeader() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.conversations.first)
        let photo = Parley.Attachment(name: "IMG_0001.jpg", contentType: "image/jpeg", kind: .image, width: 800, height: 600)
        let root = Message(id: "\(room.id)/photo-root", conversationID: room.id, threadID: "\(room.id)/photo-root",
                           sender: Person(id: "ana", name: "Ana"), text: "", replyCount: 1, attachments: [photo])
        store.messages.append(root)
        let host = NSHostingView(rootView: ThreadPane(store: store, room: room, thread: root.id).frame(width: 360, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(50)) }
        let shown = texts(host).map(\.string)
        #expect(shown.contains("Photo"), "header texts: \(shown)")
    }

    @Test func summaryNamesEveryKindOfMessageWithNoText() {
        func one(_ kind: Parley.Attachment.Kind, _ type: String = "", _ name: String = "x") -> String {
            QuotedMessage.summary(text: "", attachments: [Parley.Attachment(name: name, contentType: type, kind: kind)])
        }
        #expect(one(.image, "image/jpeg") == "Photo")
        #expect(one(.image, "image/gif") == "GIF")
        #expect(one(.video, "video/mp4") == "Video")
        #expect(one(.voice) == "Voice message")
        #expect(one(.file, "application/pdf", "plan.pdf") == "plan.pdf")
        #expect(one(.call, "", "Join video meeting") == "Join video meeting")
        #expect(one(.card, "", "Shipyard") == "Shipyard")
        #expect(one(.link, "", "example.com") == "example.com")
        #expect(QuotedMessage.summary(text: "hi", attachments: [Parley.Attachment(name: "x", kind: .image)]) == "hi")
    }
}
