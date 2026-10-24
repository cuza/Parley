import Foundation
import ParleyDomain

extension DynamiteMapper {
    /// Card text as it is built up: the string and its formatting, from Google Chat's formatted runs or its HTML.
    struct CardText {
        var text = "", formatting: [TextStyleRange] = []
        var trimmed: String { text.trimmingCharacters(in: .newlines) }
        var item: Card.Item? {
            trimmed.isEmpty
                ? nil : .text(trimmed, formatting.filter { $0.start + $0.length <= (trimmed as NSString).length })
        }
        var length: Int { (text as NSString).length }
        mutating func newline() { if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" } }
        mutating func add(_ string: String, bold: Bool = false, link: URL? = nil, styles: [TextStyleRange.Style] = []) {
            guard !string.isEmpty else { return }
            let start = length
            let count = (string as NSString).length
            text += string
            for style in styles + (bold ? [.bold] : []) + (link.map { [.link($0)] } ?? []) {
                formatting.append(TextStyleRange(style: style, start: start, length: count))
            }
        }
        /// Card text from its runs; the HTML with tags stripped when there are none.
        mutating func add(
            _ formatted: Dynamite_FormattedText, bold: Bool = false, link: URL? = nil, over: [TextRunStyle] = []
        ) {
            let start = length
            var colours: [TextStyleRange] = []
            if formatted.segments.isEmpty { addHTML(formatted.html, bold: bold) }
            for segment in formatted.segments {
                if segment.hasLink {
                    let target = segment.link.originalHref.isEmpty ? segment.link.href : segment.link.originalHref
                    add(segment.link.text, bold: bold, link: URL(string: target))
                    continue
                }
                let run = segment.run
                var styles: [TextRunStyle] = []
                for style in run.styles {
                    switch style {
                    case .italic: styles.append(.italic)
                    case .underline: styles.append(.underline)
                    case .strikethrough: styles.append(.strike)
                    case .code, .codeBlock: styles.append(.code)
                    default: break
                    }
                }
                let runStart = length
                add(run.text, bold: bold || run.weight >= 2, styles: styles)  // 2 on button labels, 3 for the HTML's <b>
                // A coloured run ("Open" in green) keeps its colour; grey runs take the text's own colour.
                // ponytail: the light theme's colour in both themes; use `dark` too if a colour reads badly on dark.
                let light = run.colorPair.light
                if run.hasColorPair, !Self.grey(light), length > runStart {
                    colours.append(
                        TextStyleRange(style: .color(0xFF00_0000 | light), start: runStart, length: length - runStart))
                }
                if run.styles.contains(.br) { text += "\n" }
            }
            if let link, length > start {
                formatting.append(TextStyleRange(style: .link(link), start: start, length: length - start))
            }
            if length > start {
                formatting += over.map { TextStyleRange(style: $0, start: start, length: length - start) }
            }
            formatting += colours  // after `over`, so a run's colour wins over the label's grey
        }
        /// Card text that came only as HTML, with the subset Google Chat's cards allow: <b>, <i>, <u>, <s>, <font
        /// color>, <a href>, <br>, lists. Other tags are dropped, their text kept.
        mutating func addHTML(_ html: String, bold: Bool) {
            var open: [String: Int] = [:]
            var colours: [UInt32?] = []
            var links: [URL?] = []
            var rest = html[...]
            func emit(_ piece: Substring) {
                let string = DynamiteMapper.strippingTags(String(piece))  // entities only: `piece` has no tags
                guard !string.isEmpty else { return }
                let start = length
                add(
                    string, bold: bold || open["b", default: 0] > 0, link: links.last ?? nil,
                    styles: Self.htmlStyles.compactMap { open[$0.tag, default: 0] > 0 ? $0.style : nil })
                if let colour = colours.last ?? nil, !Self.grey(colour) {
                    formatting.append(TextStyleRange(style: .color(colour), start: start, length: length - start))
                }
            }
            let tag = /<(\/?)([a-zA-Z]+)([^>]*)>/
            while let match = rest.firstMatch(of: tag) {
                emit(rest[..<match.range.lowerBound])
                rest = rest[match.range.upperBound...]
                let closing = !match.output.1.isEmpty
                let attributes = String(match.output.3)
                let name =
                    switch match.output.2.lowercased() {
                    case "strong": "b"
                    case "em": "i"
                    case "strike", "del": "s"
                    case let other: other
                    }
                switch name {
                case "br": text += "\n"
                case "li" where !closing:
                    newline()
                    text += "• "
                case "ul", "ol", "p", "div": newline()
                case "font":
                    if closing {
                        _ = colours.popLast()
                    } else {
                        let hex = attributes.firstMatch(of: /color\s*=\s*["']?#([0-9a-fA-F]{6})/).flatMap {
                            UInt32($0.output.1, radix: 16)
                        }
                        colours.append(hex.map { 0xFF00_0000 | $0 } ?? colours.last ?? nil)
                    }
                case "a":
                    if closing {
                        _ = links.popLast()
                    } else {
                        links.append(
                            attributes.firstMatch(of: /href\s*=\s*["']([^"']+)["']/).flatMap {
                                URL(string: DynamiteMapper.strippingTags(String($0.output.1)))
                            })
                    }
                default: open[name, default: 0] += closing ? -1 : 1
                }
            }
            emit(rest)
        }
        private static let htmlStyles: [(tag: String, style: TextRunStyle)] = [
            ("i", .italic), ("u", .underline), ("s", .strike), ("code", .code),
        ]
        /// A grey takes the text's own colour, so it reads in both themes.
        static func grey(_ colour: UInt32) -> Bool {
            colour >> 16 & 0xFF == colour >> 8 & 0xFF && colour >> 8 & 0xFF == colour & 0xFF
        }
        typealias TextRunStyle = TextStyleRange.Style
    }
}
