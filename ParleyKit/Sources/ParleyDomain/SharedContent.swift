import Foundation

/// What a conversation's loaded messages share, for the info panel: newest first, each attachment or link once.
public struct SharedContent: Equatable {
    public struct Item: Sendable, Hashable, Identifiable {
        public var attachment: Attachment  // links are `.link` attachments: a preview's, or one made from the URL
        public var date: Date
        public var sender: String
        public var messageID: MessageID?  // the message that shared it: server results page on from it
        public var id: String { attachment.url?.absoluteString ?? "\(attachment.name)|\(attachment.contentType)" }
        public init(attachment: Attachment, date: Date, sender: String, messageID: MessageID? = nil) {
            self.attachment = attachment
            self.date = date
            self.sender = sender
            self.messageID = messageID
        }
    }
    public private(set) var media: [Item] = [], files: [Item] = [], links: [Item] = []

    public init(_ messages: [Message]) {
        var seen: Set<String> = []
        for message in messages.filter({ $0.delivery == .sent && !$0.isSystem }).sorted(by: {
            $0.createdAt > $1.createdAt
        }) {
            for attachment in message.attachments + Self.links(in: message) {
                let item = Item(
                    attachment: attachment, date: message.createdAt, sender: message.sender.name, messageID: message.id)
                guard seen.insert(item.id).inserted else { continue }
                switch attachment.kind {
                case .image, .video: media.append(item)
                case .file, .voice: files.append(item)
                case .link: links.append(item)
                case .call, .card: break  // calls and cards are not shared content
                }
            }
        }
    }
    /// Web links in the text: annotated ones, then any the server left bare.
    #if canImport(Darwin)
        private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        static func bareLinks(in text: String) -> [URL] {
            detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        }
    #else
        /// Foundation off Apple platforms has no link detector: web addresses up to the next space, without the
        /// punctuation that ends a sentence.
        static func bareLinks(in text: String) -> [URL] {
            text.matches(of: /https?:\/\/\S+/).compactMap { match in
                var link = Substring(match.output)
                while let last = link.last, ".,;:!?)\"'".contains(last) { link = link.dropLast() }
                return URL(string: String(link))
            }
        }
    #endif
    private static func links(in message: Message) -> [Attachment] {
        let annotated = message.formatting.compactMap { range -> URL? in
            if case .link(let url) = range.style { url } else { nil }
        }
        let bare = bareLinks(in: message.text)
        return (annotated + bare).filter { ["http", "https"].contains($0.scheme?.lowercased()) }
            .map { Attachment(name: $0.absoluteString, kind: .link, url: $0) }
    }
}
