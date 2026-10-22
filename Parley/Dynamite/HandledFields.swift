import Foundation
import SwiftProtobuf

/// What of a message Parley handles, field by field, and the walk that finds the rest. Every field set on a
/// `Dynamite_Message` is read with SwiftProtobuf's own traversal as a path of field numbers ("15.7.2.2.13.3"; the
/// elements of a repeated field share its path). A set path `handled` doesn't cover is a gap, and so is a field Parley's
/// proto doesn't declare, read from the unknown fields and written with a "?" ("15.7.2.2.13.?6"). A few kinds Google
/// Chat tells apart by value, not by field, are checked by `flags`. Numbers only: no text, names or ids.
enum MessageCoverage {
    /// Paths Parley draws, uses or deliberately ignores. "a.b" is that field; "a.b.*" also everything below it. The
    /// fields that hold a listed path are handled with it.
    static let handled: [String] = [
        // Bookkeeping: ids, times, the sender (name, avatar, the app it posts for), local id, labels (a star).
        "1.*", "2.*", "3", "4", "8", "14", "17", "28", "40", "43.1", "43.2",
        // Undeclared bookkeeping Google Chat sends on most messages, with nothing to draw: the message's history
        // state (18), message state 1 (visible to everyone, 20; 2, only I see it: "Only visible to you"), two enums (24, 25), the posting app's ids and display
        // settings (29, 49), a reply's place in its thread (34), the creator again (39), the emoji count (44), sort
        // keys (48), attachment edit times (53, 54).
        "18.*", "20=1", "20=2", "24", "25", "29.*", "34", "39.*", "44", "48.*", "49.*", "53", "54",
        // Text and its annotations' ranges and kinds.
        "10", "11.1", "11.2", "11.3", "11.20", "11.29",
        // Drive files, mentions, links (with Google's extras around a link: none is a preview), formatting.
        "11.4.1", "11.4.2", "11.4.3", "11.4.4", "11.4.7", "11.4.8", "11.4.14", "11.30.*",
        "11.5.*", "11.7.*", "11.8.1", "11.8.2", "11.8.3.*",   // 8.3: a list's kind (numbered) and depth
        // A YouTube link's own case (the URL's card draws it), Google's unique id per annotation, a card-capability
        // marker, the features a message needs (all ones Parley has), a Gemini turn's bookkeeping: nothing to draw.
        "11.6.*", "11.19", "11.25.*", "11.28.*", "11.42.*",
        // Annotation bookkeeping: an upload's local id (9), the app a link preview is consented for (24; the card names it).
        "11.9", "11.24.*",
        // Uploads: images, files, voice messages.
        "11.10.1", "11.10.3", "11.10.4", "11.10.5.*", "11.10.18.*", "11.10.20", "11.10.22",
        // An upload's bookkeeping: its annotation id (6), a video reference (7), DLP status (12), Google Chat's hashes and
        // markers (8, 13, 24–26). Nothing to draw.
        "11.10.6", "11.10.7.*", "11.10.8", "11.10.12.*", "11.10.13", "11.10.24", "11.10.25", "11.10.26",
        // System lines: membership changes, renames and details.
        "11.11.1", "11.11.2.*", "11.11.3.*", "11.11.5.*", "11.11.7", "11.14.4.*", "11.14.6.*", "11.14.7.*", "11.14.8",
        // Not drawn on purpose: a membership change's member id copy (4) and each member's role and states (6: the
        // change's kind words the line), a room update's space kind, the same before and after (14.10).
        "11.11.4.*", "11.11.6.*", "11.14.10.*",
        // Meet: a meeting link, a call; Calendar and Tasks chips.
        "11.12.1.1", "11.12.1.2", "11.12.1.3", "11.16.1", "11.16.6.1.1.2", "11.16.6.1.1.3", "11.16.6.2", "11.16.3.*", "11.16.4.*",
        // Not drawn on purpose: a meeting link's dial-in number, PIN and tel.meet links (1.5, 1.8, 1.10), its settings and
        // flags (1.11, 1.15, 1.19, 2, 3). Google Chat's chip says only "Join video meeting" too.
        "11.12.1.5", "11.12.1.8", "11.12.1.10", "11.12.1.11", "11.12.1.15", "11.12.1.19", "11.12.2", "11.12.3",
        // Custom emoji, space chips, Gemini's sources and "Show thinking".
        "11.26.*", "11.33.*", "11.37.1", "11.37.2.2", "11.37.2.3", "11.37.2.4.1", "11.37.2.5.1", "11.37.2.6", "11.37.2.7", "11.43.1.1.*",
        // A slash command's message: its text as typed, as Google Chat draws it (the command's app, name and id: nothing to draw).
        "11.15.*",
        // A source's snippet picture (4.2) and the thinking log's status (43.1.2): not drawn.
        "11.37.2.4.2.*", "11.43.1.2",
        // Cards: the app, the attachment id, header (with its picture), section header (plain or formatted), a collapsible
        // section's first widgets (and its toggle's buttons, below), the features the card needs (a note when Parley
        // lacks one), whether a line splits its sections.
        "15.6.*", "15.8", "15.7.13", "15.7.1.1.*", "15.7.1.2.*", "15.7.1.3", "15.7.1.4", "15.7.1.5", "15.7.2.1", "15.7.2.3", "15.7.2.4", "15.7.2.5.*",
        "15.7.10",
        // Not drawn on purpose: an add-on copy of a card Google Chat draws once (15.2), the card's name (4), its background
        // (9; the system's), style hints and padding Google Chat sends for its own layout (card 7, 11, 15, 16; header
        // 6–10; section 11, 12; the toggle's alignment 7.1: it sits at the start).
        "15.2.*", "15.7.4", "15.7.7", "15.7.9.*", "15.7.11.*", "15.7.15", "15.7.16",
        "15.7.1.6", "15.7.1.7", "15.7.1.8.*", "15.7.1.9.*", "15.7.1.10.*", "15.7.2.11.*", "15.7.2.12.*", "15.7.2.7.1",
    ] + widget("15.7.2.2") + column("15.7.2.2.18.2.4") + [
        // Columns: their wrapping, width and vertical alignment hints (two columns sit side by side, top-aligned).
        "15.7.2.2.18.1", "15.7.2.2.18.3", "15.7.2.2.18.2.1", "15.7.2.2.18.2.2", "15.7.2.2.18.2.3",
    ] + button("15.7.2.7.2") + button("15.7.2.7.3") + [
        // Bot responses (which ones are drawn: `flags`), reactions, quotes and forwards.
        "19.*", "21.1.*", "21.2", "21.3",
        "37.1.*", "37.5.*", "37.6", "37.7.*", "37.15", "37.17.1.*", "37.17.5",
        // The quoted original's state: active is the quote as shown; a deleted or edited original still reports.
        "37.3=1",
        // Not drawn on purpose: when a reaction was added (21.4), when a label was set (43.3, 43.5); a quote's times,
        // updater and legacy kind (37.2, 10, 12, 13; 4 and 16 Google Chat's own), its last edit time (14) and the quoted
        // message's own quote type (18), the quoted original's history setting (11), a forward's group extras (37.17.3, 6, 8, 9: its kind and a direct message's other
        // side; "a direct message" names it).
        "21.4", "43.3", "43.5.*", "37.2", "37.4.*", "37.10", "37.12.*", "37.13", "37.14", "37.16.*", "37.18", "37.11.*",
        "37.17.3", "37.17.6", "37.17.8.*", "37.17.9.*",
        // A copy's original in a shortcut, tombstones, private messages (whose: `flags`), translations.
        "42.*", "31.*", "32.*", "35.*", "47.*",
    ]
    /// A button: a text button's label, on-click, look (type, colour), disabled, alt text and icon; an icon button's
    /// icon, on-click, alt text, disabled. Not drawn on purpose: style hints (a text button's 12, 14–16; an icon
    /// button's 8, 10) and a Material icon's fill, weight and grade (an SF Symbol or the icon's picture stands for it).
    private static func button(_ path: String) -> [String] {
        (["1.1.*", "1.4", "1.5", "1.7.*", "1.8", "1.9", "1.10.1", "1.12.*", "1.14.*", "1.15", "1.16", "1.10.2", "1.10.3", "1.10.4",
          "2.1", "2.3", "2.5", "2.6.1", "2.6.2", "2.6.3", "2.6.4", "2.8", "2.10"] + onClick("1.2") + onClick("2.2")).map { "\(path).\($0)" }
    }
    /// What a click does: send an action, open a link (Google's redirect and the target; how it opens is the add-ons'
    /// business), or open an overflow menu of items, each with its own on-click (an item's icon isn't drawn).
    private static func onClick(_ path: String) -> [String] {
        ["2", "5.1", "5.5", "5.2", "5.3", "5.4", "15.1.1.*", "15.1.2", "15.1.4"].map { "\(path).\($0)" }
            + (path.split(separator: ".").count < 8 ? onClick("\(path).15.1.3") : [])   // a menu item's own on-click
    }
    /// A widget: paragraph, button list, image (and what a click on it does), text field, selection, date picker, decorated
    /// text (with its end button or switch), divider, columns. Not drawn on purpose: its alignment (15) and padding (24)
    /// hints, a divider's style, an image's 6, a decorated text's style hints (13–15, 19, 20) and its icon's 5.
    private static func widget(_ path: String) -> [String] {
        (["3.*", "9.1", "9.3", "9.4", "9.6", "16.*", "15", "24.*"] + onClick("9.2") + textInput("11") + selection("12") + date("14")
         + decorated("13") + ["8"]).map { "\(path).\($0)" } + button("\(path).8")
    }
    /// A column's widgets, numbered their own way: date picker 1, image 2, decorated text 3, selection 4, text field 5,
    /// paragraph 6, buttons 7.
    private static func column(_ path: String) -> [String] {
        (["2.1", "2.3", "2.4", "2.6", "6.*"] + onClick("2.2") + date("1") + decorated("3") + selection("4") + textInput("5")).map { "\(path).\($0)" }
            + button("\(path).7")
    }
    /// A text field: name, label, value, hint, one line or several, placeholder, its limit and kind. Not used: Google
    /// Chat's own hints (2, 5, 12, 14, 18, 20–22).
    private static func textInput(_ path: String) -> [String] {
        ["1", "2", "3", "4", "5", "6", "7", "12", "13.*", "14", "15", "18", "20", "21", "22"].map { "\(path).\($0)" }
    }
    /// A selection: name, kind, items (text, value, picked, the line under it), label, a multiple choice's limit.
    private static func selection(_ path: String) -> [String] {
        ["1", "2", "3.1", "3.2", "3.3", "3.6", "5", "7"].map { "\(path).\($0)" }
    }
    /// A date or time picker: name, label, kind, the moment, its zone offset.
    private static func date(_ path: String) -> [String] {
        ["1", "2", "3", "4", "5"].map { "\(path).\($0)" }
    }
    /// A decorated text: icon (and its alt text), labels, text, on-click, wrapping, end button or switch.
    private static func decorated(_ path: String) -> [String] {
        (["1", "2.*", "3.*", "4.*", "8", "9", "10", "11.1", "11.2", "11.3", "11.5", "13", "14", "15", "19.*", "20.*",
          "7.1", "7.2", "7.3", "7.6", "22.1", "22.2", "22.3", "22.6"] + onClick("5")).map { "\(path).\($0)" }
            + button("\(path).6") + button("\(path).21")
    }
    /// Paths whose varint value is part of the path ("20=2"): kinds that decide how a message is drawn.
    static let valued: Set<String> = ["20", "37.3"]

    /// What Parley doesn't draw on `proto`, in path order, each once.
    static func gaps(_ proto: Dynamite_Message, selfID: String) -> [String] {
        var walked = proto
        // Not drawn on purpose: Gemini's feedback row (Google Chat's other clients don't draw it either) and a Meet
        // call's card (its chip says the same).
        walked.appAttachments.removeAll(where: DynamiteMapper.isFeedbackRow)
        if DynamiteMapper.isMeetCall(proto) { walked.appAttachments = [] }
        var walker = Walker()
        try? walked.traverse(visitor: &walker)
        var gaps = walker.paths.filter { !covered($0) } + flags(walked, selfID: selfID)
        var seen = Set<String>()
        gaps = gaps.filter { seen.insert($0).inserted }
        return gaps.sorted { order($0).lexicographicallyPrecedes(order($1)) }
    }
    /// Kinds of a whole message Parley doesn't draw: bot responses other than an app suggestion, a slash command's own
    /// message, the "couldn't respond" row on a message without text, or the card saying what an app needs (types 1–4)
    /// ("19.1=<type>"); a private message for someone else ("35").
    private static func flags(_ proto: Dynamite_Message, selfID: String) -> [String] {
        let bots = proto.botResponses.filter { ![DynamiteMapper.appSuggestion, DynamiteMapper.slashCommandEcho].contains($0.type)
            && !((1...4).contains($0.type) && (proto.textBody.isEmpty || $0.hasRequiredAction)) }
        return bots.map { "19.1=\($0.type)" }
            + (proto.privateMessageViewers.contains { $0.viewer.id != selfID } ? ["35"] : [])
    }

    private static let exact: Set<String> = {
        var paths = Set<String>()
        for entry in handled {
            let path = entry.hasSuffix(".*") ? String(entry.dropLast(2)) : entry
            if !entry.hasSuffix(".*") { paths.insert(path) }
            var parts = path.split(separator: ".").dropLast()
            while !parts.isEmpty { paths.insert(parts.joined(separator: ".")); parts = parts.dropLast() }
        }
        return paths
    }()
    private static let subtrees = Set(handled.filter { $0.hasSuffix(".*") }.map { String($0.dropLast(2)) })
    static func covered(_ path: String) -> Bool {
        let plain = path.replacingOccurrences(of: "?", with: "")
        if exact.contains(plain) { return true }
        let numbers = plain.split(separator: "=").first.map(String.init) ?? plain
        var prefix = ""
        for part in numbers.split(separator: ".") {
            prefix += prefix.isEmpty ? String(part) : "." + part
            if subtrees.contains(prefix) { return true }
        }
        return false
    }
    private static func order(_ path: String) -> [Int] {
        path.split(whereSeparator: { $0 == "." || $0 == "=" }).map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    /// Collects the path of every set field, declared or not.
    private struct Walker: SwiftProtobuf.Visitor {
        var path: [String] = []
        var paths: [String] = []
        private var seen = Set<String>()

        private mutating func add(_ field: Int, value: UInt64? = nil, declared: Bool = true) {
            let name = (path + [declared ? "\(field)" : "?\(field)"]).joined(separator: ".")
            let plain = (path + ["\(field)"]).joined(separator: ".").replacingOccurrences(of: "?", with: "")
            let full = MessageCoverage.valued.contains(plain) ? "\(name)=\(value.map(String.init) ?? "")" : name
            if seen.insert(full).inserted { paths.append(full) }
        }
        mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws { add(fieldNumber) }
        mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws { add(fieldNumber, value: UInt64(bitPattern: value)) }
        mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws { add(fieldNumber, value: value) }
        mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws { add(fieldNumber, value: value ? 1 : 0) }
        mutating func visitSingularStringField(value: String, fieldNumber: Int) throws { add(fieldNumber) }
        mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws { add(fieldNumber) }
        mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {
            add(fieldNumber, value: UInt64(bitPattern: Int64(value.rawValue)))
        }
        mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
            add(fieldNumber)
            path.append("\(fieldNumber)")
            defer { path.removeLast() }
            try value.traverse(visitor: &self)
        }
        mutating func visitMapField<K, V: MapValueType>(fieldType: _ProtobufMap<K, V>.Type, value: _ProtobufMap<K, V>.BaseType, fieldNumber: Int) throws { add(fieldNumber) }
        mutating func visitMapField<K, V>(fieldType: _ProtobufEnumMap<K, V>.Type, value: _ProtobufEnumMap<K, V>.BaseType, fieldNumber: Int) throws where V.RawValue == Int { add(fieldNumber) }
        mutating func visitMapField<K, V>(fieldType: _ProtobufMessageMap<K, V>.Type, value: _ProtobufMessageMap<K, V>.BaseType, fieldNumber: Int) throws { add(fieldNumber) }
        /// Fields the proto doesn't declare: their numbers, and a varint's value where `valued` asks for it. Their
        /// contents are not read (their shape is unknown).
        mutating func visitUnknown(bytes: Data) throws {
            var reader = WireReader(bytes: [UInt8](bytes)[...])
            while let key = reader.varint(), key >> 3 > 0 {
                let field = Int(key >> 3)
                switch key & 7 {
                case 0: add(field, value: reader.varint(), declared: false)
                case 1: add(field, declared: false); guard reader.skip(8) else { return }
                case 2: add(field, declared: false); guard let length = reader.varint(), reader.skip(Int(length)) else { return }
                case 5: add(field, declared: false); guard reader.skip(4) else { return }
                default: add(field, declared: false); return   // a group: not used by Google Chat
                }
            }
        }
    }
}
