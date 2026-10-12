import AppKit
import Testing
@testable import Parley

/// Pixel QA for pictures in bubbles: rows rendered through the real row view (hosted in a window), own and others', light and
/// dark, at 1x and 2x. Pictures are generated here (gradients), never real ones.
@MainActor struct MediaBubbleSnapshotTests {
    struct Case { let name: String; let pictures: [Parley.Attachment]; let configure: (inout Message) -> Void; let kind: ConversationKind }
    static let sam = QuotedMessage(sender: "Sam", text: "the original")
    static func picture(_ name: String, _ w: Int, _ h: Int, kind: Parley.Attachment.Kind = .image) -> Parley.Attachment { Parley.Attachment(name: name, kind: kind, width: w, height: h) }
    static let cases: [Case] = [
        Case(name: "media-only", pictures: [picture("p-only", 1200, 800)], configure: { _ in }, kind: .direct),
        Case(name: "quote+picture", pictures: [picture("p-quote", 1200, 800)], configure: { $0.quote = sam }, kind: .direct),
        Case(name: "caption+picture", pictures: [picture("p-caption", 1200, 800)], configure: { $0.text = "a caption" }, kind: .direct),
        Case(name: "name+picture", pictures: [picture("p-name", 1200, 800)], configure: { $0.text = "hello" }, kind: .group),
        Case(name: "name+media-only", pictures: [picture("p-name-only", 1200, 800)], configure: { _ in }, kind: .group),
        Case(name: "caption+two", pictures: [picture("p-two-a", 1200, 800), picture("p-two-b", 900, 900)], configure: { $0.text = "two" }, kind: .direct),
        Case(name: "picture+file", pictures: [picture("p-file", 1200, 800)], configure: { $0.attachments.append(Parley.Attachment(name: "r.pdf", contentType: "application/pdf", kind: .file)) }, kind: .direct),
        Case(name: "video", pictures: [picture("p-video", 1280, 720, kind: .video)], configure: { $0.text = "clip" }, kind: .direct),
        Case(name: "gif", pictures: [picture("p-gif", 480, 270)], configure: { $0.quote = sam }, kind: .direct),
        Case(name: "narrow-portrait", pictures: [picture("p-narrow", 400, 1200)], configure: { $0.text = String(repeating: "A long caption that wraps. ", count: 8) }, kind: .direct),
        Case(name: "very-wide", pictures: [picture("p-wide", 1600, 400)], configure: { $0.text = "wide" }, kind: .direct),
        Case(name: "tall-beyond-cap", pictures: [picture("p-tall", 300, 1500)], configure: { $0.quote = sam }, kind: .direct),
        Case(name: "narrow-media-only", pictures: [picture("p-narrow-only", 60, 300)], configure: { _ in }, kind: .direct),
    ]

    /// A gradient far from every bubble colour (orange to green), at the picture's natural aspect.
    static func image(for attachment: Parley.Attachment) -> NSImage {
        let w = attachment.width ?? 320, h = attachment.height ?? 240
        let px = 96, size = CGSize(width: w >= h ? px : px * w / h, height: h > w ? px : px * h / w)
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.95, green: 0.5, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 1)] as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    struct Shot { let view: MessageRowView, layout: RowLayout, rep: NSBitmapImageRep, scale: CGFloat, window: NSWindow }
    static func render(_ c: Case, own: Bool, dark: Bool, scale: CGFloat, width: CGFloat = 700) async throws -> Shot {
        for p in c.pictures { ImageCache.shared.setObject(image(for: p), forKey: ImageCache.key(p) as NSString) }
        var message = Message(id: "m", conversationID: "c", sender: RowLayout.alexForTests, text: "", createdAt: Date(timeIntervalSince1970: 1_700_000_000), attachments: c.pictures)
        c.configure(&message)
        let row = TimelineRow(message: message, begins: true, ends: true, newDay: false)
        let layout = RowLayout.make(row, width: width, own: own, kind: c.kind)
        let view = MessageRowView()
        view.configure(row, own: own, kind: c.kind, meID: own ? "alex" : "me", layout: layout, actions: MessageRowActions())
        view.frame = CGRect(x: 0, y: 0, width: width, height: layout.height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        for _ in 0..<4 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(layout.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        // PARLEY_SNAPSHOT_DIR=<dir> keeps each picture for a look.
        if let dir = ProcessInfo.processInfo.environment["PARLEY_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(c.name)-\(own ? "own" : "other")-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
        }
        return Shot(view: view, layout: layout, rep: rep, scale: scale, window: window)
    }
}

extension MediaBubbleSnapshotTests.Shot {
    func color(_ x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let px = min(rep.pixelsWide - 1, max(0, Int(x * scale))), py = min(rep.pixelsHigh - 1, max(0, Int(y * scale)))
        let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) ?? .clear
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
    func bubbleColor(own: Bool, dark: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var out: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = (own ? BubblePalette.own : BubblePalette.incoming).usingColorSpace(.sRGB) ?? .clear
            out = (c.redComponent, c.greenComponent, c.blueComponent)
        }
        return out
    }
}

extension RowLayout { static let alexForTests = Person(id: "alex", name: "Alex Example") }

@Suite(.serialized) @MainActor struct MediaBubbleQATests {
    typealias S = MediaBubbleSnapshotTests
    static let combos: [(own: Bool, dark: Bool, scale: CGFloat)] = [(false, false, 2), (true, false, 2), (false, true, 2), (true, true, 2), (true, false, 1), (false, true, 1)]

    /// A picture in a bubble leaves a 1 pt edge of bubble colour along each side it meets (Telegram's), and is picture
    /// right inside it.
    @Test func aPictureInABubbleHasAOnePointEdgeOfBubble() async throws {
        for c in S.cases where c.name != "media-only" && c.name != "narrow-media-only" && c.name != "name+media-only" {
            for combo in Self.combos {
                let shot = try await S.render(c, own: combo.own, dark: combo.dark, scale: combo.scale)
                let bubble = shot.bubbleColor(own: combo.own, dark: combo.dark), half = 0.5 / combo.scale
                for (index, frame) in shot.layout.attachments.enumerated() where shot.layout.attachmentCorners[index] != nil {
                    var bad: [String] = []
                    var y = frame.minY + RowLayout.mediaRadius + 1
                    while y < frame.maxY - RowLayout.mediaRadius - 1 {
                        if !shot.layout.time.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.maxX - 1, y: y)) {
                            for (edge, inside) in [(frame.minX - half, frame.minX + half), (frame.maxX + half, frame.maxX - half)] {
                                if !isBubble(shot.color(edge, y), bubble) { bad.append("edge \(edge),\(y) not bubble") }
                                if isBubble(shot.color(inside, y), bubble) { bad.append("picture \(inside),\(y) is bubble") }
                            }
                        }
                        y += 1
                    }
                    #expect(bad.isEmpty, "\(c.name) own=\(combo.own) dark=\(combo.dark) @\(combo.scale)x picture \(index): \(bad.prefix(3))")
                }
            }
        }
    }

    private func isBubble(_ p: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat), _ bubble: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
        abs(p.r - bubble.r) < 0.04 && abs(p.g - bubble.g) < 0.04 && abs(p.b - bubble.b) < 0.04
    }

    /// Media alone: the picture's own edge pixels are opaque all along its straight edges (nothing, not even a bubble, shows through).
    @Test func aPictureAloneIsOpaqueToItsEdges() async throws {
        for c in S.cases where ["media-only", "narrow-media-only", "name+media-only"].contains(c.name) {
            for combo in Self.combos {
                let shot = try await S.render(c, own: combo.own, dark: combo.dark, scale: combo.scale)
                #expect(shot.layout.mediaOnly)
                let f = shot.layout.attachments[0], r = RowLayout.mediaRadius + 1, step = 1 / combo.scale
                var y = f.minY + r, bad: [String] = []
                while y < f.maxY - r {
                    let l = shot.color(f.minX + step / 2, y), rr = shot.color(f.maxX - step / 2, y)
                    if l.a < 0.99 || rr.a < 0.99 { bad.append("y\(y) left \(l) right \(rr)") }
                    y += 1
                }
                #expect(bad.isEmpty, "\(c.name) \(combo): \(bad.prefix(2))")
            }
        }
    }

    /// The bubble drawn is the layout's size; outside its rounded corners the row is transparent.
    @Test func theBubbleIsTheLayoutsSizeWithTransparentCorners() async throws {
        for c in S.cases where c.name != "name+media-only" {   // its layout box holds the name, but no bubble is drawn
            for combo in Self.combos {
                let shot = try await S.render(c, own: combo.own, dark: combo.dark, scale: combo.scale)
                let b = shot.layout.bubble, tail = shot.layout.tail ? RowLayout.tailWidth : 0   // sticks out on the sender's side
                var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
                let data = try #require(shot.rep.bitmapData), spp = shot.rep.samplesPerPixel, stride = shot.rep.bytesPerRow
                for py in 0..<shot.rep.pixelsHigh { for px in Int((b.minX - 7) * combo.scale)..<shot.rep.pixelsWide where data[py * stride + px * spp + spp - 1] > 128 {
                    let x = CGFloat(px) / combo.scale, y = CGFloat(py) / combo.scale
                    minX = min(minX, x); maxX = max(maxX, x + 1 / combo.scale); minY = min(minY, y); maxY = max(maxY, y + 1 / combo.scale)
                } }
                // From just left of the bubble on: the avatar beside it is not part of it.
                #expect(abs(minX - (b.minX - (combo.own ? 0 : tail))) <= 2 && abs(maxX - (b.maxX + (combo.own ? tail : 0))) <= 2 && abs(minY - b.minY) <= 1 && abs(maxY - b.maxY) <= 1,
                        "\(c.name) own=\(combo.own) @\(combo.scale)x drew \(minX)..\(maxX) x \(minY)..\(maxY), layout \(b)")
                var corners = [(b.minX + 0.5, b.minY + 0.5), (b.maxX - 0.5, b.minY + 0.5), (b.minX + 0.5, b.maxY - 0.5), (b.maxX - 0.5, b.maxY - 0.5)]
                if tail > 0 { corners.removeLast(combo.own ? 1 : 2); if !combo.own { corners.append((b.maxX - 0.5, b.maxY - 0.5)) } }   // the tail's corner is the bubble's
                for (x, y) in corners {
                    #expect(shot.color(x, y).a < 0.1, "\(c.name) own=\(combo.own) corner \(x),\(y) is drawn")
                }
            }
        }
    }

    /// A picture narrower than its frame is centred over a blur of itself: the margins are neither bubble nor empty.
    @Test func aNarrowPictureHasABlurredFill() async throws {
        for name in ["narrow-portrait", "tall-beyond-cap", "narrow-media-only"] {
            let c = try #require(S.cases.first { $0.name == name })
            for combo in Self.combos {
                let shot = try await S.render(c, own: combo.own, dark: combo.dark, scale: combo.scale)
                let bubble = shot.bubbleColor(own: combo.own, dark: combo.dark)
                let f = shot.layout.attachments[0], natural = c.pictures[0]
                let aspect = CGFloat(natural.width ?? 1) / CGFloat(natural.height ?? 1)
                let shown = min(f.width, f.height * aspect)
                #expect(shown < f.width - 4, "\(name) should be narrower than its frame")
                let p = shot.color(f.minX + (f.width - shown) / 4, f.midY)
                #expect(p.a > 0.99 && !isBubble(p, bubble), "\(name) own=\(combo.own) dark=\(combo.dark): margin pixel \(p)")
            }
        }
    }

    /// The pill is inside the last picture and clear of a video's play button.
    @Test func theTimePillIsInsideThePictureAndClearOfThePlayButton() async throws {
        for c in S.cases where c.pictures.last.map(RowLayout.isMedia) == true && c.name != "picture+file" {
            let shot = try await S.render(c, own: false, dark: false, scale: 2)
            guard shot.layout.text == nil else { continue }   // a caption sits under the picture, and the time with it
            let f = try #require(shot.layout.attachments.last), t = shot.layout.time
            #expect(f.contains(t), "\(c.name): pill \(t) outside picture \(f)")
            #expect(t.maxX == f.maxX - RowLayout.mediaPillMargin.width && t.maxY == f.maxY - RowLayout.mediaPillMargin.height, "\(c.name): pill margin")
            #expect(!CGRect(x: f.midX - 22, y: f.midY - 22, width: 44, height: 44).intersects(t), "\(c.name): pill over the play button")
        }
    }

    /// A bubble a picture fills draws its tail on a run's last message, as any bubble does.
    @Test func aBubbleAPictureFillsDrawsItsTail() async throws {
        for name in ["caption+picture", "quote+picture"] {
            let c = try #require(S.cases.first { $0.name == name })
            let shot = try await S.render(c, own: false, dark: false, scale: 2)
            #expect(shot.layout.tail && shot.view.bubbleView.tail, "\(name)")
        }
    }

    /// The hover tooltip (`.help`) must not take clicks: the picture's host view is what a click reaches.
    @Test func aClickOnAPictureReachesItsHostView() async throws {
        let c = try #require(S.cases.first { $0.name == "caption+picture" })
        let shot = try await S.render(c, own: false, dark: false, scale: 2)
        let f = shot.layout.attachments[0]
        let hit = shot.view.hitTest(CGPoint(x: f.midX, y: f.midY))
        #expect(hit === shot.view.attachmentViews[0])
    }
}
