import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// The coverage walk: every field set on a message, declared in Parley's proto or not, is either handled
/// (`MessageCoverage.handled`) or reported, as numbers only.
struct MessageCoverageTests {
    private func message(text: String = "hi", _ configure: (inout Dynamite_Message) -> Void = { _ in }) -> Dynamite_Message {
        .with { m in m.id.messageID = "m1"; m.textBody = text; configure(&m) }
    }
    private func gaps(_ proto: Dynamite_Message) -> [String] { MessageCoverage.gaps(proto, selfID: "me") }
    /// `message` with an undeclared varint field `field` = `value` added, as Google Chat would send it.
    private func adding<M: SwiftProtobuf.Message>(_ field: Int, _ value: UInt64 = 1, to message: M) throws -> M {
        func varint(_ n: UInt64) -> [UInt8] {
            var n = n, out: [UInt8] = []
            repeat { out.append(UInt8(n & 0x7F) | (n > 0x7F ? 0x80 : 0)); n >>= 7 } while n > 0
            return out
        }
        return try M(serializedBytes: try message.serializedBytes() + varint(UInt64(field) << 3) + varint(value))
    }
    private func card(_ widgets: [Dynamite_CardWidget], text: String = "hi") -> Dynamite_Message {
        message(text: text) { $0.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = widgets }] }] }
    }

    @Test func handledShapesStayQuiet() throws {
        #expect(gaps(message()).isEmpty)
        #expect(gaps(message { $0.botResponses = [.with { $0.type = 6; $0.bot.name = "App" }] }).isEmpty)   // an app suggestion
        #expect(gaps(message(text: "") { $0.botResponses = [.with { $0.type = 2 }] }).isEmpty)   // "couldn't respond"
        #expect(gaps(message { $0.privateMessageViewers = [.with { $0.viewer.id = "me" }] }).isEmpty)
        #expect(gaps(try adding(20, 1, to: message())).isEmpty)   // visible to everyone
        #expect(gaps(card([.with { $0.buttons = [.with { $0.textButton.onClick.action = Data([1]) }] }])).isEmpty)
        // Gemini's feedback row (icon buttons), which Google Chat's other clients don't draw either.
        let icons = try adding(2, to: Dynamite_CardButton())
        #expect(gaps(message { $0.appAttachments = [.with { $0.attachmentID = "accessory_actions"
            $0.card.sections = [.with { $0.widgets = [.with { $0.buttons = [icons] }] }] }] }).isEmpty)
    }
    @Test func aFieldParleyDoesNotDrawIsReportedByItsPath() {
        // Declared but not drawn: client-side-encrypted content.
        #expect(gaps(message { $0.translation.text = "x"; $0.encryptedContent = Data([1]) }) == ["50"])   // a translation is drawn
    }
    @Test func aFieldTheProtoDoesNotDeclareIsReportedByPathAndNumber() throws {
        let row = try adding(12, to: Dynamite_DecoratedText.with { $0.text.html = "Connect your account" })   // an end icon
        #expect(gaps(card([.with { $0.decoratedText = row }])) == ["15.7.2.2.13.?12"])
        let widget = try adding(25, to: Dynamite_CardWidget()), styled = try adding(13, to: Dynamite_TextButton())
        #expect(gaps(card([widget])) == ["15.7.2.2.?25"])   // a widget kind Parley doesn't know
        #expect(gaps(card([.with { $0.buttons = [.with { $0.textButton = styled }] }])) == ["15.7.2.2.8.1.?13"])   // a button's field Parley doesn't know
        #expect(gaps(card([.with { $0.buttons = [.with { $0.imageButton.materialIcon.name = "x" }] }])).isEmpty)   // an icon button is drawn
        #expect(gaps(message { $0.messageState = 2 }).isEmpty)   // only I see it: "Only visible to you"
    }
    @Test func kindsToldApartByValueAreReported() throws {
        #expect(gaps(message { $0.botResponses = [.with { $0.type = 9 }] }) == ["19.1=9"])
        #expect(gaps(message { $0.botResponses = [.with { $0.type = 2 }] }) == ["19.1=2"])   // with text and no required action
        #expect(gaps(message { $0.privateMessageViewers = [.with { $0.viewer.id = "someone" }] }) == ["35"])
        let bold = Dynamite_CardWidget.with { $0.textParagraph.text.segments = [.with { $0.run.text = "Q"; $0.run.weight = 3 }] }
        #expect(gaps(card([bold])).isEmpty)   // the HTML's <b>, bold
        #expect(gaps(card([.with { $0.textParagraph.text.html = "<b>Q</b><br>A" }])).isEmpty)   // HTML only: its formatting is drawn
        let dialog = Data(try Dynamite_CardAction.with { $0.function = "f"; $0.interaction = 1 }.serializedBytes() as [UInt8])
        #expect(gaps(card([.with { $0.buttons = [.with { $0.textButton.onClick.action = dialog }] }])).isEmpty)   // Parley opens the dialog
        #expect(gaps(card([.with { $0.textParagraph.text.html = "Q" }], text: "")).isEmpty)   // only cards: no bubble, as Google Chat
    }
    @Test func gapsCarryNoContent() throws {
        let row = try adding(12, to: Dynamite_DecoratedText.with { $0.text.html = "Secret for Alice"; $0.onClick.openLink.url = "https://secret.example.com" })
        let proto = try adding(99, 424242, to: message(text: "Secret text") {
            $0.creator.userID.id = "user-id-777"; $0.creator.email = "alice@example.com"
            $0.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = [.with { $0.decoratedText = row }] }] }]
        })
        let found = gaps(proto).joined(separator: " ")
        #expect(found == "15.7.2.2.13.?12 ?99")
        for leak in ["Secret", "Alice", "alice@", "secret.example.com", "user-id-777", "424242"] { #expect(!found.contains(leak)) }
    }

    /// Every gap the real messages below have, so that a new one fails the test. Remove an entry once Parley draws it.
    static let knownUnsupported: Set<String> = [
        // Annotations: Drive and link extras, Meet details, Gemini's agent fields (not decoded yet)
        "11.4.?5", "11.4.?13", "11.4.?14", "11.4.?15", "11.4.?17", "11.10.?23", "11.12.1.?5", "11.12.1.?8", "11.12.1.?10",
        "11.12.1.?11", "11.12.1.?15", "11.12.1.?19", "11.12.?2", "11.12.?3", "11.16.6.1.1.?4", "11.16.6.?3", "11.?17",
        // Quotes (not decoded yet)
        "37.?3", "37.?8", "37.?11", "37.?14", "37.?18", "37.?21", "37.17.?2",
    ]
    @Test func realMessagesAreHandledOrKnown() throws {
        var found = Set<String>()
        for fixture in Self.fixtures {
            found.formUnion(gaps(try Dynamite_Message(serializedBytes: try #require(Data(base64Encoded: String(fixture))))))
        }
        #expect(found.subtracting(Self.knownUnsupported).sorted() == [], "unsupported and not listed")
        #expect(Self.knownUnsupported.subtracting(found).sorted() == [], "listed but handled now: remove from knownUnsupported")
    }
    @Test func theFixturesAreContentFree() throws {
        // Every text, id and link is "x" or empty: no run of two or more bytes besides the tree's own structure, except
        // the id of Gemini's feedback row, a Google Chat constant Parley reads.
        let constant = Data("accessory_actions".utf8)
        for fixture in Self.fixtures {
            let data = try #require(Data(base64Encoded: String(fixture))), bytes = [UInt8](data)
            let skeleton = try #require(MessageShapes.skeleton(bytes[...], path: []))
            let runs = skeleton.matches(of: /:L([2-9]|\d{2,})\b/).map { String($0.output.0) }
            var constants = 0, rest = data[...]
            while let found = rest.firstRange(of: constant) { constants += 1; rest = rest[found.upperBound...] }
            #expect(runs == Array(repeating: ":L17", count: constants), "\(skeleton)")
        }
    }
    /// Real Google Chat messages (app cards, polls, slash commands, Drive and Meet notices, Gemini answers, quotes,
    /// forwards, uploads, voice, reactions, system lines), each reduced to its field structure: every string "x", every
    /// number 1 or a small kind, undeclared fields emptied. Binary protobuf, base64, one per line. The last two hold, as
    /// bare numbers, every path a real account's own conversations carried that the ones above don't (the second, its
    /// dialog buttons).
    static let fixtures = """
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
ChEKDCIKEgF4GgUaAwoBeBIBeBIFCgMKAXgYASABUgBaOQgNEAAYAFIpCgF4GgF4IgF4kgEGCgIQARACsAEBMgBAAWIAagC4AQHCAQDKAQDSAQCgAQFKAJoBAHIBeOABAZIBAKABAcABAsgBAroCAA==
ChEKDCIKEgF4GgUaAwoBeBIBeBIFCgMKAXgYASABUgF4WgoIHKABAeIBAggBcgF44AEBqgIxChEKDCIKEgF4GgUaAwoBeBIBeCoFCgMKAXgyAXh4ARIAIgBQAmIAagByAIABAJABAZIBAKABAcABAsgBAroCAA==
ChEKDCIKEgF4GgUaAwoBeBIBeBIVCgcKAXgQARoAEgF4GgF4KgA4AEoAGAEgAVIBeFodCCIQABgAoAEBqgIREg8SAXgaAXgyAXg4DiIAKgBaHQgiEAAYAKABAaoCERIPEgF4GgF4MgF4OA4iACoAWh0IIhAAGACgAQGqAhESDxIBeBoBeDIBeDgOIgAqAFodCCIQABgAoAEBqgIREg8SAXgaAXgyAXg4DiIAKgBaHQgiEAAYAKABAaoCERIPEgF4GgF4MgF4OA4iACoAWhkIIhAAGACgAQGqAg0SCxIBeBoBeDIBeDgOWhkIIhAAGACgAQGqAg0SCxIBeBoBeDIBeDgOWhkIIhAAGACgAQGqAg0SCxIBeBoBeDIBeDgOWggIJqABA9ICAFoKCBygAQHiAQIIClqLAQgiEAAYAaABAaoCfwoBeBIPEgF4GgF4MgF4OA4iACoAEg8SAXgaAXgyAXg4DiIAKgASDxIBeBoBeDIBeDgOIgAqABIPEgF4GgF4MgF4OA4iACoAEg8SAXgaAXgyAXg4DiIAKgASCxIBeBoBeDIBeDgOEgsSAXgaAXgyAXg4DhILEgF4GgF4MgF4OA5yAXjgAQGSAQCgAQHAAQHIAQPqAQCQAgG6AgCKAwA=
ChEKDCIKEgF4GgUaAwoBeBIBeBIFCgMKAXgYASABUgBaCAgToAEDigEAcgF44AECkgEAoAEBwAEByAED
ChEKDCIKEgF4GgUaAwoBeBIBeBIFCgMKAXgYASABUgF4cgF4qgELCgMKAXgQARgBIgDgAQGSAQCgAQHAAQLIAQK6AgA=
ChEKDCIKEgF4GgUKAwoBeBIBeBIFCgMKAXgYASABUgF4WiQIDFodCAISAwoBeBoFCgMKAXgqBwoFCgMKAXgiADIAOAGgAQNyAXjgAQKSAQCgAQHAAQLIAQK6AgA=
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
""".split(separator: "\n")
}
