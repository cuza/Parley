import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Uploads, Drive files and links: what a message's annotations become as attachments.
struct AttachmentMappingTests: MapperFixtures {
    private static let base = "https://chat.google.com/api/get_attachment_url?"
    private func upload(_ name: String, type: String, token: String, size: (Int32, Int32)? = nil) -> Dynamite_Annotation
    {
        .with { annotation in
            annotation.uploadMetadata.attachmentToken = token
            annotation.uploadMetadata.contentName = name
            annotation.uploadMetadata.contentType = type
            if let size {
                annotation.uploadMetadata.originalDimension.width = size.0
                annotation.uploadMetadata.originalDimension.height = size.1
            }
        }
    }
    private func attachments(_ annotations: [Dynamite_Annotation], text: String = "") throws -> Message {
        var proto = msg("m1", text: text)
        proto.annotations = annotations
        var message = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: people))
        for index in message.attachments.indices { message.attachments[index].cacheKey = nil }  // ImageDiskCacheTests checks keys
        return message
    }

    @Test func uploadedImageMapsToFifeThumbnailAndDownload() throws {
        let message = try attachments([upload("cat.png", type: "image/png", token: "a+b/c=", size: (800, 600))])
        #expect(message.text == "")
        #expect(
            message.attachments == [
                Attachment(
                    name: "cat.png", contentType: "image/png", kind: .image,
                    thumbnailURL: URL(
                        string: Self.base
                            + "url_type=FIFE_URL&sz=w640&content_type=image%2Fpng&rwa=true&attachment_token=a%2Bb%2Fc%3D&allow_caching=true"
                    ),
                    url: URL(
                        string: Self.base
                            + "url_type=DOWNLOAD_URL&content_type=image%2Fpng&attachment_token=a%2Bb%2Fc%3D"),
                    width: 800, height: 600)
            ])
    }
    @Test func uploadedFileHasNoThumbnailAndPercentTokenIsDecodedFirst() throws {
        let file = try #require(
            try attachments([upload("q3.pdf", type: "application/pdf", token: "x%2By")], text: "see attached")
                .attachments.first)
        #expect(file.kind == .file && file.thumbnailURL == nil && file.width == nil)
        #expect(
            file.url
                == URL(
                    string: Self.base + "url_type=DOWNLOAD_URL&content_type=application%2Fpdf&attachment_token=x%2By"))
        let video = try #require(try attachments([upload("clip.mp4", type: "video/mp4", token: "v")]).attachments.first)
        #expect(video.kind == .video && video.thumbnailURL?.absoluteString.contains("url_type=FIFE_URL") == true)
    }
    @Test func driveFileOpensItsLink() throws {
        let drive = Dynamite_Annotation.with {
            $0.driveMetadata.id = "d1"
            $0.driveMetadata.title = "Roadmap"
            $0.driveMetadata.mimetype = "application/vnd.google-apps.document"
            $0.driveMetadata.thumbnailURL = "https://lh3.googleusercontent.com/thumb"
            $0.driveMetadata.thumbnailWidth = 200
            $0.driveMetadata.thumbnailHeight = 100
            $0.interactionData.url.url = "https://docs.google.com/document/d/d1/edit"
        }
        #expect(
            try attachments([drive], text: "https://docs.google.com/document/d/d1/edit").attachments == [
                Attachment(
                    name: "Roadmap", contentType: "application/vnd.google-apps.document", kind: .link,
                    thumbnailURL: URL(string: "https://lh3.googleusercontent.com/thumb"),
                    url: URL(string: "https://docs.google.com/document/d/d1/edit"),
                    width: 200, height: 100, domain: "docs.google.com")
            ])
    }
    /// Google Chat sends a Doc's size but no thumbnail URL: the preview comes from the file id, over the session's cookies.
    @Test func driveFileWithoutThumbnailURLPreviewsFromItsID() throws {
        let drive = Dynamite_Annotation.with {
            $0.driveMetadata.id = "d1"
            $0.driveMetadata.title = "Plan"
            $0.driveMetadata.thumbnailWidth = 800
            $0.driveMetadata.thumbnailHeight = 1035
            $0.interactionData.url.url = "https://docs.google.com/document/d/d1/edit"
        }
        let mapped = try #require(
            try attachments([drive], text: "https://docs.google.com/document/d/d1/edit").attachments.first)
        #expect(
            mapped.thumbnailURL
                == URL(string: "https://lh3.google.com/mail-doc-preview/d1?authuser=0&auditContext=thumbnail"))
        #expect(mapped.width == 800 && mapped.height == 1035 && mapped.domain == "docs.google.com")  // drawn as a link card
        // No size and no title, as for a Markdown file or a link that names only the file: web still draws the card,
        // with the preview from the id and the kind of file for a title (it says "no access" only if the preview fails).
        let bare = Dynamite_Annotation.with {
            $0.type = .driveDoc
            $0.driveMetadata.id = "f1"
            $0.interactionData.url.url = "https://docs.google.com/document/d/f1/edit"
        }
        let card = try #require(try attachments([bare], text: "x").attachments.first)
        #expect(
            card.thumbnailURL
                == URL(string: "https://lh3.google.com/mail-doc-preview/f1?authuser=0&auditContext=thumbnail"))
        #expect(card.domain == "docs.google.com" && card.name == "Google Doc")
    }
    /// A Drive file picked from Google Chat's @ list, as web sends it: its title in the text, an inline chip (format 1)
    /// with the file's link, and the type in field 14. The title links to the file, and the card keeps its type.
    @Test func aDriveChipLinksItsTitleInTheText() throws {
        let chip = Dynamite_Annotation.with {
            $0.type = .driveFile
            $0.startIndex = 0
            $0.length = 4
            $0.chipRenderType = .renderIfPossible
            $0.inlineRenderFormat = 1
            $0.driveMetadata.id = "d1"
            $0.driveMetadata.title = "Plan"
            $0.driveMetadata.mimeType = "application/vnd.google-apps.document"
            $0.interactionData.url.url = "https://docs.google.com/document/d/d1/edit"
        }
        let message = try attachments([chip], text: "Plan and QA")
        #expect(
            message.formatting == [
                TextStyleRange(
                    style: .link(URL(string: "https://docs.google.com/document/d/d1/edit")!), start: 0, length: 4)
            ])
        #expect(message.attachments.first?.contentType == "application/vnd.google-apps.document")
    }
    /// A Drive link Google Chat marks "do not render" is a title linked in the text: web draws no chip or card for it.
    @Test func aDriveLinkMarkedDoNotRenderIsJustTheLinkedText() throws {
        let inline = Dynamite_Annotation.with {
            $0.type = .driveDoc
            $0.chipRenderType = .doNotRender
            $0.driveMetadata.id = "d1"
        }
        #expect(try attachments([inline], text: "the plan").attachments.isEmpty)
    }
    @Test func linkedGifIsAnImageAndOtherPreviewsAreLinks() throws {
        let gif = Dynamite_Annotation.with {
            $0.urlMetadata.url.url = "https://media.tenor.com/x.gif"
            $0.urlMetadata.imageURL = "https://media.tenor.com/x.gif"
            $0.urlMetadata.mimeType = "image/gif"
            $0.urlMetadata.intImageWidth = 220
            $0.urlMetadata.intImageHeight = 180
        }
        let page = Dynamite_Annotation.with {
            $0.urlMetadata.url.url = "https://example.com/a"
            $0.urlMetadata.title = "Example"
            $0.urlMetadata.imageURL = "https://example.com/og.png"
        }
        let mapped = try attachments([gif, page, .with { $0.urlMetadata.title = "no url" }], text: "links").attachments
        #expect(
            mapped == [
                Attachment(
                    name: "x.gif", contentType: "image/gif", kind: .image,
                    thumbnailURL: URL(string: "https://media.tenor.com/x.gif"),
                    url: URL(string: "https://media.tenor.com/x.gif"), width: 220, height: 180),
                Attachment(
                    name: "Example", kind: .link, thumbnailURL: URL(string: "https://example.com/og.png"),
                    url: URL(string: "https://example.com/a"), domain: "example.com"),
            ])
    }
    @Test func gifsLoadTheAnimatedOriginal() throws {
        // A resized FIFE rendition is a still frame, so an uploaded GIF shows its original.
        let upload = try #require(
            try attachments([upload("dance.gif", type: "image/gif", token: "g", size: (480, 480))]).attachments.first)
        #expect(upload.thumbnailURL == upload.url)
        // A preview without a MIME type falls back to the URL's extension, as Google Chat does.
        let link = Dynamite_Annotation.with {
            $0.urlMetadata.url.url = "https://static2.klipy.com/ii/9e/1d/d0/vfTUImNFkyNdf.gif"
        }
        let gif = try #require(try attachments([link], text: "gif").attachments.first)
        #expect(gif.kind == .image && gif.contentType == "image/gif" && gif.thumbnailURL == gif.url)
    }
    @Test func membershipEventsWithoutTextAreNotShown() {
        // Google Chat web shows no bubble for these (e.g. ROLE_TARGET_AUDIENCE_UPDATED when an app is added).
        var proto = msg("m1", text: "")
        proto.annotations = [.with { $0.type = .membershipChanged }]
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: people) == nil)
        // The history setting changing (a retention event the server marks DO_NOT_RENDER) is a system event too.
        proto.annotations = [
            .with {
                $0.type = .groupRetentionSettingsUpdated
                $0.chipRenderType = .doNotRender
            }
        ]
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: people) == nil)
        proto.annotations = []  // nothing we can decode: still shown, so it isn't silently lost
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: people)?.text == "Unsupported message")
    }
    @Test func mentionsAndFormattingAreNotAttachments() throws {
        #expect(try attachments([Dynamite_Annotation()], text: "hi").attachments.isEmpty)
        var proto = msg("m1", text: "")
        proto.annotations = [Dynamite_Annotation()]
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: people) == nil)  // no text, only metadata: a system event
    }
}
