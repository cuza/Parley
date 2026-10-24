import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Meet calls and links: a chip that joins or opens the meeting, as Google Chat shows them.
struct MeetingChipTests: CardMessageFixtures {
    @Test func aMeetCallIsAChipThatOpensTheMeeting() throws {
        let call = Dynamite_Message.with { proto in
            proto.id.messageID = "m2"
            proto.id.parentID.topicID.topicID = "m2"
            proto.creator.userID.id = "u1"
            proto.annotations = [
                .with { annotation in
                    annotation.type = .gsuiteIntegration
                    annotation.gsuiteIntegrationMetadata.meetCall = .with {
                        $0.status = .callEnded
                        $0.meeting.link.url = "https://meet.google.com/abc-defg-hij"
                    }
                }
            ]
            // The call's own card says the same; Google Chat shows the call, not the card. Google updates the message
            // as the call ends, which is not an edit.
            proto.appAttachments = [
                .with {
                    $0.card.sections = [
                        .with { $0.widgets = [.with { $0.decoratedText.text = text("Call ended", bold: true) }] }
                    ]
                }
            ]
            proto.lastEditTime = 1
        }
        let shown = try mapped(call)
        #expect(shown.text.isEmpty && !shown.edited)  // a chip, as Google Chat shows a call
        let chip = try #require(shown.attachments.first)
        #expect(
            chip.kind == .call && chip.call == .ended && chip.name == "Call ended"
                && chip.url == URL(string: "https://meet.google.com/abc-defg-hij"))
        #expect(chip.opensInBrowser && chip.detail == "Google Meet")
        #expect(QuotedMessage.summary(text: shown.text, attachments: shown.attachments) == "Call ended")  // Home and notifications
    }
    /// A Meet link carries a VIDEO_CALL annotation: Google Chat shows a card to join under the link.
    @Test func aMeetLinkGetsAJoinChip() throws {
        var link = Dynamite_Message.with { proto in
            proto.id.messageID = "m3"
            proto.id.parentID.topicID.topicID = "m3"
            proto.creator.userID.id = "u1"
            proto.textBody = "https://meet.google.com/abc-defg-hij"
        }
        // The annotation as Google Chat sends it: type 11, then field 12 holding {1: {1 name, 2 code, 3 url, 15: {flags}}, 2: false}.
        func ld(_ field: Int, _ bytes: [UInt8]) -> [UInt8] { [UInt8(field << 3 | 2), UInt8(bytes.count)] + bytes }
        let url = Array("https://meet.google.com/abc-defg-hij".utf8)
        let space =
            ld(1, Array("spaces/abcdefghijklmn".utf8)) + ld(2, Array("abc-defg-hij".utf8)) + ld(3, url)
            + ld(15, [0x08, 0x01])
        let annotation = [0x08, 0x0B, 0x10, 0x00, 0x18, 0x24] + ld(12, ld(1, space) + [0x10, 0x00])
        var bytes: [UInt8] = try link.serializedBytes()
        bytes += ld(11, annotation)
        link = try Dynamite_Message(serializedBytes: Data(bytes))
        let shown = try mapped(link)
        #expect(shown.text == "https://meet.google.com/abc-defg-hij")
        let chip = try #require(shown.attachments.first)
        #expect(
            chip.kind == .call && chip.call == .join && chip.name == "Join video meeting"
                && chip.url == URL(string: "https://meet.google.com/abc-defg-hij"))
    }
    /// A video meeting started from the composer: no text, only the meeting's VIDEO_CALL annotation (start 0, length 0).
    /// Google Chat shows it as a "Join video meeting" card; it is a message, not a system event.
    @Test func aVideoMeetingWithNoTextShowsItsJoinChip() throws {
        let proto = Dynamite_Message.with { built in
            built.id.messageID = "v1"
            built.id.parentID.topicID.topicID = "v1"
            built.creator.userID.id = "alex"
            built.messageType = .userMessage
            built.annotations = [
                .with { annotation in
                    annotation.type = .videoCall
                    annotation.startIndex = 0
                    annotation.length = 0
                    annotation.chipRenderType = .render
                    annotation.videoCallMetadata = .with {
                        $0.meetingSpace = .with { $0.url = "https://meet.google.com/abc-defg-hij?hs=122" }
                    }
                }
            ]
        }
        let shown = try mapped(proto)
        #expect(!shown.isSystem && shown.text.isEmpty)
        let chip = try #require(shown.attachments.first)
        #expect(
            chip.kind == .call && chip.call == .join && chip.name == "Join video meeting"
                && chip.url?.host() == "meet.google.com")
    }
}
