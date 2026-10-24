import AppKit
import ParleyDomain

extension ComposerTextView {
    /// A picked mention: who, and the `@Name` text it was inserted as. A run whose text no longer matches is plain text again.
    /// `userID` is a person's id, or a chip's conversation id, so it is plain text.
    struct MentionToken: Hashable {
        let userID: String
        let text: String
        var emoji: String?
        var link: URL?
        var app = false
    }
    static let mentionKey = NSAttributedString.Key("Parley.composer.mention")
    /// A conversation chip: a `MentionToken` whose id is the conversation's.
    static let chipKey = NSAttributedString.Key("Parley.composer.chip")
    static let driveKey = NSAttributedString.Key("Parley.composer.drive")  // a Drive file's chip: its `DriveFile`
    /// A picked slash command (a `SlashCommand`) over its name at the start.
    static let commandKey = NSAttributedString.Key("Parley.composer.command")
    /// The tokens typed text never joins and Delete removes whole: mentions, chips, Drive files, commands.
    static let tokenKeys = [mentionKey, chipKey, commandKey, driveKey]
    /// On a custom emoji's attachment character: the emoji, which `draftText` and `formatting` turn into U+FFFD and its range.
    static let customEmojiKey = NSAttributedString.Key("Parley.composer.customEmoji")
    var animatesEmoji: Bool { emojiAnimation.playing }

    /// Replaces `range` (the `@` query) with an `@Name` token and a space, and puts the caret after them.
    func insertMention(_ person: Person, replacing range: NSRange, app: Bool = false) {
        let text = "@" + person.name
        var attributes = typingAttributes
        attributes[Self.mentionKey] = MentionToken(userID: person.id.rawValue, text: text, app: app)
        replace(range, with: NSAttributedString(string: text, attributes: Self.visual(attributes)), space: true)
    }
    /// Replaces `range` (a Chat link) with the conversation's chip: its name, as Google Chat's composer does.
    /// `link`: the pasted link the chip replaces, sent with it as Google Chat's composer does (a message's link keeps its
    /// message); nil for a space picked from the @ list, which sends the space's own link.
    func insertChip(_ room: Conversation, replacing range: NSRange, link: URL?) {
        var attributes = typingAttributes
        attributes[Self.chipKey] = MentionToken(
            userID: room.id.rawValue, text: room.name, emoji: room.emoji, link: link)
        // A space picked from the list gets a space after it, as a mention does; a pasted link keeps what follows it.
        replace(
            range, with: NSAttributedString(string: room.name, attributes: Self.visual(attributes)), space: link == nil)
    }
    /// Replaces `range` (an @ query) with the Drive file's title as its chip, and a space, as Google Chat's composer does.
    func insertDrive(_ file: DriveFile, replacing range: NSRange) {
        var attributes = typingAttributes
        attributes[Self.driveKey] = file
        replace(range, with: NSAttributedString(string: file.title, attributes: Self.visual(attributes)), space: true)
    }
    /// Replaces `range` (the "/" query) with the command's name and a space; the message then invokes the command.
    func insertCommand(_ command: SlashCommand, replacing range: NSRange) {
        var attributes = typingAttributes
        attributes[Self.commandKey] = command
        replace(range, with: NSAttributedString(string: command.name, attributes: Self.visual(attributes)), space: true)
    }
    /// Puts `token` in place of `range`, with a plain space after it when `space`, as one undoable edit, and the caret after.
    private func replace(_ range: NSRange, with token: NSAttributedString, space: Bool) {
        guard let storage = textStorage else { return }
        let token = NSMutableAttributedString(attributedString: token)
        if space { token.append(NSAttributedString(string: " ", attributes: typingAttributes)) }
        guard shouldChangeText(in: range, replacementString: token.string) else { return }
        storage.replaceCharacters(in: range, with: token)
        setSelectedRange(NSRange(location: range.location + token.length, length: 0))
        didChangeText()
    }
    func mentionRange(at index: Int) -> NSRange? {
        guard let storage = textStorage, index < storage.length else { return nil }
        var range = NSRange()
        for key in Self.tokenKeys
        where storage.attribute(
            key, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil
        { return range }
        return nil
    }

    /// Finds the `@` query at the caret (not one inside a token), filters `mentionPeople`, and shows or hides the list.
    func updateMention() {
        let caret = selectedRange()
        var query =
            caret.length == 0
            ? MentionQuery.slash(in: string, caret: caret.location)
                ?? MentionQuery.nearest(in: string, caret: caret.location) : nil
        if query?.range.location != dismissedMention { dismissedMention = nil }
        if let found = query,
            dismissedMention != nil
                || [Self.mentionKey, Self.commandKey].contains(where: {
                    textStorage?.attribute($0, at: found.range.location, effectiveRange: nil) != nil
                })
        {
            query = nil
        }
        if let query, query.command, mentionQuery?.command != true || mentionQuery?.text != query.text {
            needSlashCommands?(query.text)
        } else if let query, mentionQuery?.shortcode != query.shortcode || mentionQuery?.command == true {
            (query.shortcode ? needCustomEmoji : needMembers)?()
        }
        if let query, query.shortcode, !query.text.isEmpty,
            mentionQuery?.shortcode != true || mentionQuery?.text != query.text
        {
            searchCustomEmoji?(query.text)
        }
        if let query, !query.shortcode, !query.command, query.chip == nil,
            mentionQuery?.text != query.text || mentionQuery?.shortcode == true || mentionQuery == nil
        {
            needMentionResults?(query.text)  // the directory's people, the conversation's apps, Drive files
        }
        if query == nil, caret.length == 0,
            let link = MentionQuery.chatLink(in: string, caret: caret.location, among: chipConversations),
            link.range.location != dismissedMention,
            textStorage?.attribute(Self.chipKey, at: link.range.location, effectiveRange: nil) == nil
        {
            query = link
        }
        let matches: [Suggestion] =
            query.map { query in
                if let room = query.chip { return [.space(room)] }
                if query.command { return SlashCommand.filter(slashCommands, by: query.text).map(Suggestion.command) }
                // Every match a workspace's thousands of emoji give (to 100), in a list that scrolls past 8 rows.
                return query.shortcode
                    ? MentionQuery.filter(customEmoji, by: query.text, limit: 100).map(Suggestion.emoji)
                        + Self.standardEmoji(query.text)
                    : people(query.text).map(Suggestion.person)
                        + mentionApps.matching(query.text, limit: 4) {
                            MentionQuery.filter($0, by: query.text, limit: 4)
                        }.map(Suggestion.app)
                        + MentionQuery.filter(files: driveFiles, by: query.text).map(Suggestion.file)
                        + MentionQuery.filter(spaces: chipConversations, by: query.text).map(Suggestion.room)
            } ?? []
        if query?.text != mentionQuery?.text || matches != mentionMatches { mentionSelection = 0 }
        mentionQuery = query
        mentionMatches = matches
        showMentions()
    }
    /// The @ list's People: matching members first, then the directory's matches who aren't members, up to 8.
    private func people(_ text: String) -> [Person] {
        let members = MentionQuery.filter(mentionPeople, by: text)
        let known = Set(mentionPeople.map(\.id))
        let others = directoryPeople.matching(text, limit: 8) { MentionQuery.filter($0, by: text) }.filter {
            !known.contains($0.id)
        }
        return Array((members + others).prefix(8))
    }
    func showMentions() {
        guard let query = mentionQuery, !mentionMatches.isEmpty, let window, window.firstResponder === self else {
            mentionPopup.close()
            return
        }
        let anchor = firstRect(forCharacterRange: NSRange(location: query.range.location, length: 1), actualRange: nil)
        mentionPopup.show(mentionMatches, selected: mentionSelection, above: anchor, in: window, loadImage: loadImage) {
            [weak self] item in
            guard let self, let query = self.mentionQuery else { return }
            self.insert(item, replacing: query.range)
        }
    }
    func insert(_ suggestion: Suggestion, replacing range: NSRange) {
        switch suggestion {
        case .person(let person): insertMention(person, replacing: range)
        case .emoji(let emoji): insertCustomEmoji(emoji, replacing: range, space: true)
        case .unicode(let emoji): insertText(emoji.character + " ", replacementRange: range)
        case .space(let room):
            insertChip(room, replacing: range, link: URL(string: (string as NSString).substring(with: range)))
        case .room(let room): insertChip(room, replacing: range, link: nil)
        case .file(let file): insertDrive(file, replacing: range)
        case .app(let app): insertMention(app, replacing: range, app: true)
        case .command(let command) where command.action != nil:  // runs now: the "/" query goes
            insertText("", replacementRange: range)
            runCommand?(command)
        case .command(let command): insertCommand(command, replacing: range)
        }
    }
    /// Standard emoji for a `:shortcode` of two letters or more (one would catch ":D"), as the picker's search finds
    /// them; "thumbs_up" and "folded-hands" read as words.
    private static func standardEmoji(_ text: String) -> [Suggestion] {
        guard text.count >= 2 else { return [] }
        return EmojiCatalog.search(
            text.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "),
            frequent: EmojiUsage().top(.max)
        ).prefix(20).map(Suggestion.unicode)
    }

    /// Replaces `range` (the selection, or a `:shortcode` query) with the emoji's picture, and a space after a query.
    func insertCustomEmoji(_ emoji: CustomEmoji, replacing range: NSRange, space: Bool = false) {
        replace(range, with: Self.customEmojiToken(emoji, attributes: typingAttributes), space: space)
        loadCustomEmojiImages()
    }
    /// One attachment character drawn as `MessageTextStyle` draws custom emoji; with no picture (deleted), the U+FFFD itself.
    static func customEmojiToken(_ emoji: CustomEmoji, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString
    {
        var attributes = visual(attributes.filter { $0.key != mentionKey })
        attributes[customEmojiKey] = emoji
        let picture = MessageTextStyle.customEmoji(emoji, attributes: attributes)
        return picture.length == 1 ? picture : NSAttributedString(string: "\u{FFFD}", attributes: attributes)
    }
    /// Pictures not in `ImageCache` yet draw as placeholders: fetch them, then redraw.
    /// Animated ones play (`EmojiAnimation`).
    func loadCustomEmojiImages() {
        let all = customEmojiPictures
        emojiAnimation.update(all)
        let pictures = all.filter { ImageCache.cached($0) == nil }
        guard !pictures.isEmpty else { return }
        let load = loadImage
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            for picture in pictures { _ = try? await ImageCache.load(picture, load) }
            guard let self, !Task.isCancelled else { return }
            needsDisplay = true
            emojiAnimation.update(all)
        }
    }
    var customEmojiPictures: Set<Attachment> {
        guard let storage = textStorage else { return [] }
        var pictures = Set<Attachment>()
        storage.enumerateAttribute(Self.customEmojiKey, in: NSRange(location: 0, length: storage.length)) {
            value, _, _ in
            if let picture = (value as? CustomEmoji)?.image { pictures.insert(picture) }
        }
        return pictures
    }
}
