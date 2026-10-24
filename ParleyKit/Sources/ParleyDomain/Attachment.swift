import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Google Drive file, as the @ list offers it and a message's Drive chip carries it.
public struct DriveFile: Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var mimeType: String
    public init(id: String, title: String, mimeType: String) {
        self.id = id
        self.title = title
        self.mimeType = mimeType
    }
}
/// An uploaded file or image, a Drive file, or a link preview. Bytes come from `ChatBackend.attachmentData`.
public struct Attachment: Hashable, Codable, Sendable {
    /// link: opens in the browser; voice: a recorded voice message; call: a Google Meet call; card: an app's card.
    public enum Kind: String, Codable, Sendable { case image, video, file, link, voice, call, card }
    public var name: String
    public var contentType = ""
    public var kind: Kind
    public var thumbnailURL: URL?
    public var url: URL?  // full size / download / page
    public var width: Int?  // known pixel size, so the timeline can reserve space
    public var height: Int?
    public var snippet: String?  // link preview description
    public var domain: String?  // set only on link previews, which render as a card
    public var uploadToken: String?  // opaque, from `ChatBackend.upload`: set on a local file once it is uploaded
    public var voice: Voice?  // set on `.voice`
    public var call: CallStatus?  // set on `.call`
    public var huddle: Bool?  // true on a huddle's `.call`, which never rings
    public var cacheKey: String?  // "<message id>#<place>": its picture's cache key, as its URL changes on every load
    public var card: Card?  // set on `.card`
    public enum CallStatus: String, Codable, Sendable { case started, missed, ended, join }  // join: a Meet link
    /// Links and calls open in the browser; the rest preview with Quick Look.
    public var opensInBrowser: Bool { kind == .link || kind == .call }
    public init(
        name: String, contentType: String = "", kind: Kind, thumbnailURL: URL? = nil, url: URL? = nil,
        width: Int? = nil, height: Int? = nil,
        snippet: String? = nil, domain: String? = nil, uploadToken: String? = nil, voice: Voice? = nil,
        call: CallStatus? = nil,
        huddle: Bool? = nil, cacheKey: String? = nil, card: Card? = nil
    ) {
        self.name = name
        self.contentType = contentType
        self.kind = kind
        self.thumbnailURL = thumbnailURL
        self.url = url
        self.width = width
        self.height = height
        self.snippet = snippet
        self.domain = domain
        self.uploadToken = uploadToken
        self.voice = voice
        self.call = call
        self.huddle = huddle
        self.cacheKey = cacheKey
        self.card = card
    }
}
/// What a voice message carries besides its audio, as Google Chat sends it.
public struct Voice: Hashable, Codable, Sendable {
    public var duration: TimeInterval
    public var waveform: [Int] = []  // one 0…100 level per 100 ms; empty: computed from the audio once it loads
    public var transcript: String?  // the server's, once it has transcribed the message
    public init(duration: TimeInterval, waveform: [Int] = [], transcript: String? = nil) {
        self.duration = duration
        self.waveform = waveform
        self.transcript = transcript
    }
    /// Google Chat names a recording after the time it was made.
    public static func fileName(at date: Date = .now) -> String {
        "UserRecording_\(Int64((date.timeIntervalSince1970 * 1000).rounded())).m4a"
    }
    /// Google Chat labels its AAC recordings this way.
    public static let contentType = "audio/mpeg"
}

public enum AttachmentError: Error, LocalizedError, Equatable {
    case notAFile(String)
    case empty(String)
    case tooLarge(String)
    public var errorDescription: String? {
        switch self {
        case .notAFile(let name): "“\(name)” isn’t a file that can be attached."
        case .empty(let name): "“\(name)” is empty."
        case .tooLarge(let name): "“\(name)” is larger than Google Chat’s 200 MB limit."
        }
    }
}
extension Attachment {
    /// The content types of a Calendar event's and a Tasks task's chip, as the Google Chat client gives them.
    public static let calendarType = "text/calendar", taskType = "application/x-google-task"
    /// The name of a Drive file Google Chat named only by its kind (also "Google Doc", "Google Sheet"…).
    public static let untitledDrive = "Google Drive file"
    /// A Drive file Google Chat named only by its kind: when its preview fails, the viewer can't open it, and the card says so.
    public var untitledDrive: Bool {
        kind == .link
            && [Self.untitledDrive, "Google Doc", "Google Sheet", "Google Slides", "Google Form"].contains(name)
    }
    /// Google Chat refuses larger uploads.
    public static let maxUploadBytes = 200_000_000
    /// Not sent yet: a file on this Mac, shown from disk until the server's copy replaces it.
    public var isLocalFile: Bool { url?.isFileURL == true }
    /// A file picked, pasted or dropped into the composer. Images keep their pixel size so the echo reserves its space.
    public static func localFile(at url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard url.isFileURL, values?.isRegularFile == true, let size = values?.fileSize else {
            throw AttachmentError.notAFile(name)
        }
        guard size > 0 else { throw AttachmentError.empty(name) }
        guard size <= maxUploadBytes else { throw AttachmentError.tooLarge(name) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        var file = Attachment(
            name: name, contentType: type.preferredMIMEType ?? "application/octet-stream",
            kind: type.conforms(to: .image) ? .image : .file, url: url)
        if file.kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            file.width = properties[kCGImagePropertyPixelWidth] as? Int
            file.height = properties[kCGImagePropertyPixelHeight] as? Int
            file.thumbnailURL = url
        }
        return file
    }
}
