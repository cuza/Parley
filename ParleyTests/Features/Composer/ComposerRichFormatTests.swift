import AppKit
import Testing

@testable import Parley
@testable import ParleyDomain

@MainActor struct ComposerRichFormatTests {
    private func composer(_ text: String) -> (ComposerTextView, NSWindow) {
        let scroll = NativeComposer.makeScrollView(delegate: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        guard let view = scroll.documentView as? ComposerTextView else {
            preconditionFailure("The composer scroll view holds a ComposerTextView")
        }
        view.load(text, [])
        window.makeFirstResponder(view)
        return (view, window)
    }
    /// The store never replaces the field's text under an input method's unfinished text (an accent being typed, an
    /// inline prediction): the composition would land in the replaced text and repeat words.
    @Test func theFieldIsNotReloadedWhileComposing() {
        let (view, _) = composer("hola")
        #expect(view.acceptsReload)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.setMarkedText(
            "´", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.acceptsReload)
        view.unmarkText()
        #expect(view.acceptsReload)
    }
    @Test func underlineAndColourGoOnTheSelection() {
        let (view, _) = composer("hi there")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.toggle(.underline)
        view.setSelectedRange(NSRange(location: 3, length: 5))
        view.color(.blue)
        #expect(
            Set(view.formatting) == [
                TextStyleRange(style: .underline, start: 0, length: 2),
                TextStyleRange(style: .color(TextColor.blue.argb), start: 3, length: 5),
            ])
        view.color(nil)  // the default swatch takes the colour off
        #expect(view.formatting == [TextStyleRange(style: .underline, start: 0, length: 2)])
    }
    @Test func theCurrentColourIsTheSelectionsOrWhatIsTypedNext() {
        let (view, _) = composer("hi there")
        #expect(view.currentColor == nil)
        view.setSelectedRange(NSRange(location: 3, length: 5))
        view.color(.green)
        #expect(view.currentColor == .green)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.currentColor == nil)
        view.color(.red)  // at a caret: for what is typed next
        #expect(view.currentColor == .red)
    }
    /// One range per block over whole lines, its newline included unless it ends the message, as web sends it.
    @Test func codeBlocksAndQuotesCoverWholeLines() {
        let (view, _) = composer("c1\nc2\nx\nq1\nq2")
        view.setSelectedRange(NSRange(location: 1, length: 3))  // from "c1" into "c2"
        view.toggle(.codeBlock)
        view.setSelectedRange(NSRange(location: 9, length: 0))  // a caret in "q1"…
        view.setSelectedRange(NSRange(location: 9, length: 4))  // …to "q2"
        view.toggle(.quote)
        #expect(
            Set(view.formatting) == [
                TextStyleRange(style: .codeBlock, start: 0, length: 6),
                TextStyleRange(style: .quote, start: 8, length: 5),
            ])
    }
    @Test func aLinkGoesOnTheSelectionOrInsertsItsText() {
        let (view, _) = composer("see docs")
        view.setSelectedRange(NSRange(location: 4, length: 4))
        view.link(URL(string: "https://example.com")!, text: nil)
        #expect(
            view.formatting == [TextStyleRange(style: .link(URL(string: "https://example.com")!), start: 4, length: 4)])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.link(URL(string: "https://a.b")!, text: "here")
        #expect(
            view.string == "heresee docs"
                && view.formatting.contains(
                    TextStyleRange(style: .link(URL(string: "https://a.b")!), start: 0, length: 4))
        )
    }
    @Test func editingKeepsColourAndLinks() {
        let (view, _) = composer("")
        let link = URL(string: "https://example.com")!
        view.load(
            "red link",
            [
                TextStyleRange(style: .color(TextColor.red.argb), start: 0, length: 3),
                TextStyleRange(style: .link(link), start: 4, length: 4),
            ])
        #expect(
            Set(view.formatting) == [
                TextStyleRange(style: .color(TextColor.red.argb), start: 0, length: 3),
                TextStyleRange(style: .link(link), start: 4, length: 4),
            ])
    }
    @Test func shortcutsFormatTheSelection() throws {
        let (view, _) = composer("abc")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        func press(_ key: String, _ flags: NSEvent.ModifierFlags) throws -> Bool {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: view.window!.windowNumber,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            return view.performKeyEquivalent(with: event)
        }
        #expect(try press("u", .command))
        #expect(view.formatting == [TextStyleRange(style: .underline, start: 0, length: 3)])
        var asked = false
        view.askForLink = { asked = true }
        #expect(try !press("k", .command))  // ⌘K is Jump to Conversation everywhere, the composer too
        #expect(!asked)
        #expect(try press("k", [.command, .shift]))  // Add Link is ⇧⌘K
        #expect(asked)
        #expect(try press("'", .command))  // Quote is ⌘', as Mail's
        #expect(try !press("i", [.command, .shift]))  // ⇧⌘I is Conversation Info
        view.load("", [])
        #expect(try press("i", .command))  // ⌘I is italic, even in an empty composer
    }
    /// The field stays horizontal: no Layout Orientation in its menu, and the action, sent from elsewhere, does nothing.
    @Test func theFieldHasNoVerticalLayout() throws {
        let (view, _) = composer("abc")
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window!.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.menu(for: event))
        let actions = menu.items.flatMap { [$0] + ($0.submenu?.items ?? []) }.compactMap(\.action)
        #expect(!actions.contains(#selector(NSTextView.changeLayoutOrientation(_:))))
        let vertical = NSMenuItem()
        vertical.tag = NSLayoutManager.TextLayoutOrientation.vertical.rawValue
        view.changeLayoutOrientation(vertical)
        #expect(view.layoutOrientation == .horizontal)
    }
    @Test func rightClickOffersAFormatMenu() throws {
        let (view, _) = composer("abc")
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window!.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let format = try #require(view.menu(for: event)?.items.first { $0.title == "Format" }?.submenu)
        let titles = format.items.map(\.title)
        for title in [
            "Bold", "Italic", "Underline", "Strikethrough", "Text Color", "Code", "Code Block", "Quote",
            "Bulleted List", "Link…", "Clear Formatting",
        ] {
            #expect(titles.contains(title), "\(title)")
        }
        #expect(format.items.first { $0.title == "Underline" }?.keyEquivalent == "u")
    }
}
