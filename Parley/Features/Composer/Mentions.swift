import AppKit
import ParleyDomain
import SwiftUI

/// The `@name` being typed before the caret: an `@` at the start of the text or after whitespace, then up to 40
/// characters on the same line (names have spaces). A space right after the `@` ends it.
/// With `shortcode`, a custom emoji's `:name` instead: a `:` the same way, then at least one character and no spaces.
struct MentionQuery: Equatable {
    var range: NSRange  // the `@` (or `:`) and what follows it, up to the caret
    var text: String
    var shortcode = false
    var chip: Conversation?  // a Chat link to this conversation, offered as its chip
    var command = false  // a "/command" at the message's start (`slash(in:caret:)`)

    static func find(in string: String, caret: Int, shortcode: Bool = false) -> MentionQuery? {
        let ns = string as NSString
        guard caret <= ns.length else { return nil }
        var index = caret
        while index > max(0, caret - 41) {
            index -= 1
            let unit = ns.character(at: index)
            if unit == 10 || unit == 13 || shortcode && (unit == 32 || unit == 9) { return nil }
            guard unit == (shortcode ? 58 : 64) else { continue }  // ":" or "@"
            if index > 0,
                !(Unicode.Scalar(ns.character(at: index - 1)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false)
            {
                return nil
            }
            let text = ns.substring(with: NSRange(location: index + 1, length: caret - index - 1))
            if text.first?.isWhitespace == true || shortcode && text.isEmpty { return nil }
            return MentionQuery(
                range: NSRange(location: index, length: caret - index), text: text, shortcode: shortcode)
        }
        return nil
    }
    /// A Google Chat link ending at the caret (pasted or typed) to one of `conversations`' spaces, which Google Chat's
    /// composer offers to turn into the space's chip ("Tab to replace with Town Hall"); it makes none for a DM.
    static func chatLink(in string: String, caret: Int, among conversations: [Conversation]) -> MentionQuery? {
        let ns = string as NSString
        guard caret <= ns.length, caret > 0 else { return nil }
        var start = caret
        while start > 0, let scalar = Unicode.Scalar(ns.character(at: start - 1)),
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        { start -= 1 }
        let text = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let url = URL(string: text), let link = ChatLink(url),
            let conversation = conversations.first(where: { $0.kind == .space && link.conversations.contains($0.id) })
        else { return nil }
        return MentionQuery(range: NSRange(location: start, length: caret - start), text: text, chip: conversation)
    }
    /// The query nearest the caret: a `:shortcode` typed after an `@` starts a new one.
    static func nearest(in string: String, caret: Int) -> MentionQuery? {
        let found = [find(in: string, caret: caret), find(in: string, caret: caret, shortcode: true)].compactMap { $0 }
        return found.max { $0.range.location < $1.range.location }
    }
    /// Custom emoji whose shortcode contains `query`, ignoring case; those starting with it first, then by shortcode.
    static func filter(_ emoji: [CustomEmoji], by query: String, limit: Int = 8) -> [CustomEmoji] {
        let query = query.lowercased()
        return Array(
            emoji.filter { $0.shortcode.lowercased().contains(query) }
                .sorted {
                    ($0.shortcode.lowercased().hasPrefix(query) ? 0 : 1, $0.shortcode) < (
                        $1.shortcode.lowercased().hasPrefix(query) ? 0 : 1, $1.shortcode
                    )
                }
                .prefix(limit))
    }
    /// Drive files for the @ list's Files section, as Google Chat shows them: the server's answer for the query (which
    /// matches contents too, not only titles); up to 4, or 2 recent ones for "@" alone.
    static func filter(files: Found<DriveFile>, by query: String) -> [DriveFile] {
        files.matching(query, limit: query.isEmpty ? 2 : 4) {
            $0.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }
    /// The SF Symbol for a Drive file's kind.
    static func symbol(_ file: DriveFile) -> String {
        switch file.mimeType {
        case "application/vnd.google-apps.document": "doc.text"
        case "application/vnd.google-apps.spreadsheet": "tablecells"
        case "application/vnd.google-apps.presentation": "rectangle.on.rectangle"
        case "application/vnd.google-apps.folder": "folder"
        case let type where type.hasPrefix("image/"): "photo"
        case let type where type.hasPrefix("video/"): "film"
        case "application/pdf": "doc.richtext"
        default: "doc"
        }
    }
    /// Spaces whose name, or any word of it onward, starts with `query`, as Google Chat's @ list offers them after
    /// people: up to 4, or the first 2 for "@" alone. Spaces only: Google Chat makes no DM chips.
    static func filter(spaces: [Conversation], by query: String) -> [Conversation] {
        let query = fold(query)
        let named = spaces.filter { $0.kind == .space }
        guard !query.isEmpty else { return Array(named.prefix(2)) }
        return Array(named.filter { matches($0.name, query) }.prefix(4))
    }
    /// People whose name, or any word of it onward, starts with `query`, ignoring case and accents; @all first, then by name.
    static func filter(_ people: [Person], by query: String, limit: Int = 8) -> [Person] {
        let query = fold(query)
        return Array(
            people.filter { query.isEmpty || matches($0.name, query) }.sorted { first, second in
                if (first == .everyone) != (second == .everyone) { return first == .everyone }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }.prefix(limit))
    }
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    /// Whether `name`, or any word of it onward, starts with `query` (already folded), ignoring case and accents.
    private static func matches(_ name: String, _ query: String) -> Bool {
        let name = fold(name)
        return name.split(separator: " ").contains { name[$0.startIndex...].hasPrefix(query) }
    }
}

/// A row of the composer's suggestion list: someone to @-mention, or a custom emoji for a `:shortcode`.
enum Suggestion: Hashable {
    // space: a pasted link offered as its chip; room: a space offered in the @ list
    case person(Person)
    case app(Person)
    case emoji(CustomEmoji)
    case unicode(Emoji)
    case space(Conversation)
    case room(Conversation)
    case file(DriveFile)
    case command(SlashCommand)
    /// The @ list's section, as Google Chat names it; nil in lists without sections (emoji, commands, a link's chip).
    var section: String? {
        switch self {
        case .person: "People"
        case .app: "Apps"
        case .file: "Files"
        case .room: "Spaces"
        case .emoji, .unicode, .space, .command: nil
        }
    }
    var id: String {
        switch self {
        case .person(let person): "p:" + person.id.rawValue
        case .emoji(let emoji): "e:" + emoji.id
        case .unicode(let emoji): "u:" + emoji.character
        case .space(let room): "s:" + room.id.rawValue
        case .room(let room): "r:" + room.id.rawValue
        case .file(let file): "f:" + file.id
        case .app(let app): "a:" + app.id.rawValue
        case .command(let command): "c:\(command.appID.rawValue):\(command.id)"
        }
    }
}

/// The suggestion list, in a borderless child window above the `@` (the way WebKit's text completion shows its list).
/// It never becomes key: the composer keeps focus and drives it with ↑ ↓ Return Tab Esc.
@MainActor final class MentionPopup {
    private var panel: NSPanel?

    func show(
        _ items: [Suggestion], selected: Int, above anchor: NSRect, in parent: NSWindow,
        loadImage: @escaping (Attachment, Bool) async throws -> Data, pick: @escaping (Suggestion) -> Void
    ) {
        let list = MentionList(items: items, selected: selected, loadImage: loadImage, pick: pick)
        let commands = items.contains { if case .command = $0 { true } else { false } }  // a description and the app's name too
        let size = NSSize(
            width: commands ? 440 : 260,
            height: Self.height(rows: items.count, headers: MentionList.headers(items).count))
        let panel =
            self.panel
            ?? {
                let panel = NSPanel(
                    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.contentView = ClickThroughHostingView(rootView: list)
                self.panel = panel
                return panel
            }()
        (panel.contentView as? ClickThroughHostingView<MentionList>)?.rootView = list
        panel.setFrame(
            NSRect(x: anchor.minX - 8, y: anchor.maxY + 4, width: size.width, height: size.height), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
    }
    /// Up to 8 rows tall; a longer list scrolls.
    static func height(rows: Int, headers: Int = 0) -> CGFloat {
        min(
            CGFloat(rows) * MentionList.rowHeight + CGFloat(headers) * MentionList.headerHeight,
            8 * MentionList.rowHeight) + 8
    }
    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Clicks land on the first try although the panel is never key.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct MentionList: View {
    static let rowHeight: CGFloat = 30, headerHeight: CGFloat = 22
    /// Where a section's name goes: above the first row of each section, by row index.
    static func headers(_ items: [Suggestion]) -> [Int: String] {
        var headers: [Int: String] = [:]
        var previous: String?
        for (index, item) in items.enumerated() {
            if let section = item.section, section != previous { headers[index] = section }
            previous = item.section
        }
        return headers
    }
    let items: [Suggestion]
    let selected: Int
    let loadImage: (Attachment, Bool) async throws -> Data
    let pick: (Suggestion) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let headers = Self.headers(items)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if let header = headers[index] {
                            Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .bottomLeading).padding(.horizontal, 8).frame(
                                    height: Self.headerHeight
                                )
                                .accessibilityAddTraits(.isHeader)
                        }
                        HStack(spacing: 8) {
                            switch item {
                            case .person(let person) where person == .everyone:  // as Google Chat lists it: a group symbol and who it reaches
                                Image(systemName: "person.3").frame(width: 22, height: 22)
                                Text(person.name).lineLimit(1).fixedSize()
                                Text("Everyone in the space").foregroundStyle(index == selected ? .white : .secondary)
                                    .lineLimit(1)
                            case .person(let person):
                                Avatar(name: person.name, size: 22, url: person.avatarURL)
                                Text(person.name).lineLimit(1)
                            case .emoji(let emoji):
                                CustomEmojiImage(emoji: emoji, size: 22, load: loadImage)
                                Text(emoji.text).lineLimit(1)
                            case .room(let room):
                                Avatar(name: room.name, space: true, size: 22, url: room.avatarURL, emoji: room.emoji)
                                Text(room.name).lineLimit(1)
                            case .file(let file):
                                Image(systemName: MentionQuery.symbol(file)).frame(width: 22, height: 22)
                                Text(file.title).lineLimit(1)
                            case .app(let app):
                                Avatar(name: app.name, size: 22, url: app.avatarURL)
                                Text(app.name).lineLimit(1)
                            case .unicode(let emoji):
                                Text(emoji.character).font(.system(size: 18)).frame(width: 22, height: 22)
                                Text(":" + emoji.name.replacingOccurrences(of: " ", with: "-") + ":").lineLimit(1)
                            case .space(let room):  // as Google Chat words it: "tab to replace with <space>"
                                Text("⇥").font(.caption.monospaced()).padding(.horizontal, 4).overlay(
                                    RoundedRectangle(cornerRadius: 4).stroke(.tertiary))
                                Text("to replace with").foregroundStyle(index == selected ? .white : .secondary)
                                    .lineLimit(1).fixedSize()
                                if let emoji = room.emoji {
                                    Text(emoji).font(.system(size: 16)).frame(width: 20, height: 20)
                                } else {
                                    Avatar(name: room.name, size: 20, url: room.avatarURL)
                                }
                                Text(room.name).lineLimit(1)
                            case .command(let command):  // as Google Chat lists them: the app's icon, the command, what it does, the app
                                if command.action == .meetLink {
                                    Image(systemName: "video").frame(width: 22, height: 22)
                                } else {
                                    Avatar(name: command.appName, size: 22, url: command.appAvatar)
                                }
                                Text(command.label).lineLimit(1).fixedSize()
                                Text(command.description).foregroundStyle(index == selected ? .white : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(command.appName).font(.caption).foregroundStyle(
                                    index == selected ? .white : .secondary
                                ).lineLimit(1).fixedSize()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).frame(height: Self.rowHeight)
                        .foregroundStyle(index == selected ? .white : .primary)
                        .background(
                            index == selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { pick(item) }
                        .accessibilityAddTraits(.isButton).accessibilityLabel(Self.label(item))
                        .id(item.id)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(items.count > 8 ? .automatic : .never)
            .onChange(of: selected) { if items.indices.contains(selected) { proxy.scrollTo(items[selected].id) } }  // ↑ ↓ keep it in view
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
    private static func label(_ item: Suggestion) -> String {
        switch item {
        case .person(let person) where person == .everyone: "Mention everyone in the space"
        case .person(let person): "Mention \(person.name)"
        case .emoji(let emoji): "Insert \(emoji.text)"
        case .unicode(let emoji): "Insert \(emoji.character)"
        case .space(let room): "Replace the link with \(room.name)"
        case .room(let room): "Link to \(room.name)"
        case .file(let file): "Link to the file \(file.title)"
        case .app(let app): "Mention the app \(app.name)"
        case .command(let command): "\(command.label), \(command.appName): \(command.description)"
        }
    }
}
