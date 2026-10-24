import Foundation
import ParleyDomain
import UniformTypeIdentifiers

extension DynamiteMapper {
    /// A Google Meet call, as the chip Google Chat shows: its status, opening the meeting.
    static func call(_ annotation: Dynamite_Annotation) -> Attachment? {
        // A video meeting, started from the composer or pasted as a link: Google Chat shows a card to join it.
        if case .videoCallMetadata(let meeting)? = annotation.metadata, let url = URL(string: meeting.meetingSpace.url)
        {
            return Attachment(name: "Join video meeting", kind: .call, url: url, call: .join)
        }
        let gsuite = annotation.gsuiteIntegrationMetadata
        // A Calendar event: its title and its link come in either order, so the link is whichever string is one.
        if gsuite.hasCalendar {
            let strings = [gsuite.calendar.event.first, gsuite.calendar.event.second].filter { !$0.isEmpty }
            let link = strings.compactMap { URL(string: $0) }.first { $0.scheme == "https" }
            let title = strings.first { URL(string: $0)?.scheme != "https" } ?? "Event"
            return Attachment(name: title, contentType: Attachment.calendarType, kind: .link, url: link)
        }
        if gsuite.hasTasks {
            return Attachment(
                name: gsuite.tasks.task.title.isEmpty ? "Task" : gsuite.tasks.task.title,
                contentType: Attachment.taskType, kind: .link)
        }
        guard gsuite.hasMeetCall else { return nil }
        let call = gsuite.meetCall
        let status: Attachment.CallStatus =
            switch call.status {
            case .callStarted: .started
            case .callMissed: .missed
            default: .ended
            }
        // Google Chat's wording: a huddle (meeting kind 1) has no "missed", and a missed call is "Call missed".
        let huddle = call.meeting.link.kind == 1
        let name =
            switch status {
            case .started: huddle ? "Huddle started" : "Call started"
            case .missed: huddle ? "Huddle ended" : "Call missed"
            case .ended, .join: huddle ? "Huddle ended" : "Call ended"
            }
        return Attachment(
            name: name, kind: .call, url: URL(string: call.meeting.link.url), call: status, huddle: huddle ? true : nil)
    }
    static func isMeetCall(_ proto: Dynamite_Message) -> Bool {
        proto.annotations.contains { $0.gsuiteIntegrationMetadata.hasMeetCall }
    }

    /// An uploaded file as Google Chat sends it: the server's own UploadMetadata,
    /// unchanged (its bytes are the attachment's `uploadToken`), in an UPLOAD_METADATA chip outside the text.
    static func uploadAnnotation(_ upload: Attachment) -> Dynamite_Annotation? {
        guard let token = upload.uploadToken, let bytes = Data(base64Encoded: token),
            let metadata = try? Dynamite_UploadMetadata(serializedBytes: bytes), !metadata.attachmentToken.isEmpty
        else { return nil }
        return .with { annotation in
            annotation.type = .uploadMetadata
            annotation.chipRenderType = .render
            annotation.uploadMetadata = metadata
            if let voice = upload.voice {  // the recorder's length and levels, which the server keeps for players to draw
                annotation.uploadMetadata.voiceMessageMetadata = .with {
                    let nanos = Int64((voice.duration * 1e9).rounded())
                    if nanos >= 1_000_000_000 { $0.duration.seconds = nanos / 1_000_000_000 }
                    if nanos % 1_000_000_000 != 0 { $0.duration.nanos = Int32(nanos % 1_000_000_000) }
                    $0.waveform = voice.waveform.map(Int32.init)
                }
            }
        }
    }

    /// A shared item from `list_attachments`: every link counts, also those a message shows only in its text.
    static func sharedAttachment(_ annotation: Dynamite_Annotation) -> Attachment? {
        if let attachment = attachment(annotation) { return attachment }
        guard case .urlMetadata(let link) = annotation.metadata, let url = URL(string: link.url.url),
            url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return Attachment(
            name: [link.title, link.domain, url.host() ?? ""].first { !$0.isEmpty } ?? url.absoluteString, kind: .link,
            url: url)
    }
    /// Uploads, Drive files and link previews; mentions and formatting are not attachments.
    static func attachment(_ annotation: Dynamite_Annotation) -> Attachment? {
        func size(_ width: Int32, _ height: Int32) -> (Int?, Int?) {
            width > 0 && height > 0 ? (Int(width), Int(height)) : (nil, nil)
        }
        switch annotation.metadata {
        case .uploadMetadata(let upload):
            guard !upload.attachmentToken.isEmpty else { return nil }
            let type = upload.contentType
            let (width, height) = size(upload.originalDimension.width, upload.originalDimension.height)
            let voice = self.voice(upload)
            let kind: Attachment.Kind =
                voice != nil ? .voice : type.hasPrefix("image/") ? .image : type.hasPrefix("video/") ? .video : .file
            let token = upload.attachmentToken.removingPercentEncoding ?? upload.attachmentToken
            let download = attachmentURL([
                ("url_type", "DOWNLOAD_URL"), ("content_type", type), ("attachment_token", token),
            ])
            return Attachment(
                name: upload.contentName.isEmpty ? "Attachment" : upload.contentName, contentType: type, kind: kind,
                // A resized FIFE rendition of a GIF is a still frame: show the animated original.
                thumbnailURL: kind == .file || kind == .voice
                    ? nil
                    : type == "image/gif"
                        ? download
                        : attachmentURL([
                            ("url_type", "FIFE_URL"), ("sz", "w640"), ("content_type", type), ("rwa", "true"),
                            ("attachment_token", token), ("allow_caching", "true"),
                        ]),
                url: download,
                width: width, height: height, voice: voice)
        case .driveMetadata(let drive):
            // "Do not render": the file's title is linked in the text, and Google Chat draws nothing more for it.
            guard annotation.chipRenderType != .doNotRender else { return nil }
            let (width, height) = size(drive.thumbnailWidth, drive.thumbnailHeight)
            // Otherwise a card, as web draws it, with the file's preview rendition: Drive serves it for the file id over the
            // session's cookies, with or without a size (the card's picture fails for a file the viewer can't open).
            let preview =
                drive.thumbnailURL.isEmpty && !drive.id.isEmpty
                ? drive.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap {
                    URL(string: "https://lh3.google.com/mail-doc-preview/\($0)?authuser=0&auditContext=thumbnail")
                }
                : URL(string: drive.thumbnailURL)
            let url = URL(string: annotation.interactionData.url.url)
            // Google Chat may send only the file's id: the kind of file stands in for its title.
            let kind =
                switch annotation.type {
                case .driveDoc: "Google Doc"
                case .driveSheet: "Google Sheet"
                case .driveSlide: "Google Slides"
                case .driveForm: "Google Form"
                default: Attachment.untitledDrive
                }
            return Attachment(
                name: drive.title.isEmpty ? kind : drive.title,
                contentType: drive.mimetype.isEmpty ? drive.mimeType : drive.mimetype, kind: .link,
                thumbnailURL: preview, url: url, width: width, height: height,
                domain: preview == nil ? nil : url?.host()?.lowercased() ?? "drive.google.com")  // a preview makes it a card
        case .urlMetadata(let link):
            // A YouTube video: Google Chat shows a card whatever the flags say, from the video's own thumbnail.
            if let url = URL(string: link.url.url), let id = youTubeID(url) {
                return Attachment(
                    name: "YouTube video", kind: .link,
                    thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
                    url: url, width: 320, height: 180, domain: "youtube.com")  // the 16:9 thumbnail, without the 4:3 one's black bars
            }
            // an explicit chip_render_type wins over should_not_render;
            // RICH_TEXT and inline-format links stay inline links in the text with no chip.
            let render =
                annotation.chipRenderType != .unknown
                ? annotation.chipRenderType : link.shouldNotRender ? .doNotRender : .render
            guard render != .doNotRender, link.urlSource != .richText, annotation.inlineRenderFormat != 1,
                let url = URL(string: link.url.url), url.scheme == "https" || url.scheme == "http"
            else { return nil }
            let (width, height) = size(link.intImageWidth, link.intImageHeight)
            // No MIME type: Google Chat falls back to the URL's extension.
            let type =
                !link.mimeType.isEmpty
                ? link.mimeType : UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
            let thumbnail = imageURL(link.imageURL)
            if type.hasPrefix("image/") {
                // Without an image from Google, the link itself is the picture only on a GIF service (a GIF pasted from
                // another app): any other host would be the sender's server, contacted as the chat opens.
                guard let picture = thumbnail ?? (Self.inlinesImages(url) ? url : nil) else { return nil }
                return Attachment(
                    name: !link.title.isEmpty ? link.title : url.lastPathComponent, contentType: type, kind: .image,
                    thumbnailURL: picture, url: url, width: width, height: height)
            }
            guard thumbnail != nil else { return nil }  // Google Chat shows no card, only the link in the text
            let domain = (link.domain.isEmpty ? url.host() ?? "" : link.domain).lowercased()
            return Attachment(
                name: [link.title, link.snippet, domain].first { !$0.isEmpty } ?? url.absoluteString, contentType: type,
                kind: .link,
                thumbnailURL: thumbnail, url: url, width: width, height: height,
                snippet: link.snippet.nilIfEmpty, domain: domain)
        default: return nil
        }
    }
    /// A YouTube video's id, from youtube.com/watch?v=, /shorts/ or youtu.be links.
    static func youTubeID(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let id: String?
        if host == "youtu.be" {
            id = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            id =
                url.path().hasPrefix("/shorts/")
                ? url.pathComponents.dropFirst(2).first
                : URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        } else {
            id = nil
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return id
    }
    /// A voice message: an upload with voice metadata, or an audio recording Google Chat named (one sent before the metadata was set).
    static func voice(_ upload: Dynamite_UploadMetadata) -> Voice? {
        let recording = upload.contentType.hasPrefix("audio/") && upload.contentName.hasPrefix("UserRecording_")
        guard upload.hasVoiceMessageMetadata || recording else { return nil }
        let meta = upload.voiceMessageMetadata
        let duration = meta.duration
        return Voice(
            duration: TimeInterval(duration.seconds) + TimeInterval(duration.nanos) / 1e9,
            waveform: meta.waveform.map { min(100, max(0, Int($0))) },
            transcript: upload.transcript.nilIfEmpty)
    }
    /// Query parameters in Google Chat's order; every value fully escaped (tokens carry `+`, `/`, `=`).
    private static func attachmentURL(_ query: [(String, String)]) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(
            separator: "&")
        return URL(string: "https://chat.google.com/api/get_attachment_url?" + encoded)
    }
}
