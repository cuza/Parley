import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// The card messages the card suites build, as Google Chat sends them.
protocol CardMessageFixtures {}

extension CardMessageFixtures {
    func text(_ string: String, italic: Bool = false, bold: Bool = false) -> Dynamite_FormattedText {
        .with {
            $0.segments = [
                .with {
                    $0.run = .with { run in
                        run.text = string
                        if italic { run.styles = [.italic] }
                        if bold { run.weight = 2 }
                    }
                }
            ]
        }
    }
    func link(_ url: String) -> Dynamite_CardOnClick {
        .with {
            $0.openLink = .with {
                $0.url = "https://www.google.com/url?q=x"
                $0.originalURL = url
            }
        }
    }
    func message(card: Dynamite_Card, body: String = "", id: String = "c1") -> Dynamite_Message {
        .with { proto in
            proto.id.messageID = "m1"
            proto.id.parentID.topicID.topicID = "m1"
            proto.textBody = body
            proto.creator.userID.id = "drive"
            proto.appAttachments = [
                .with {
                    $0.card = card
                    $0.attachmentID = id
                }
            ]
        }
    }
    func mapped(_ proto: Dynamite_Message) throws -> Message {
        try #require(DynamiteMapper.message(proto, in: "dm/d", selfID: "me", people: [:]))
    }
}
