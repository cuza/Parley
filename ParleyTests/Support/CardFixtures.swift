import Foundation

@testable import ParleyData

/// Apps' card actions and a dialog card, as Google Chat sends them, for the card and dialog tests.
enum CardFixtures {
    /// A Drive comment card's Reply button.
    static let reply = Wire.encoded(Dynamite_CardAction.with { $0.function = "REPLY_TO_COMMENT" })
    /// A button that opens the app's dialog.
    static let openDialog = Wire.encoded(
        Dynamite_CardAction.with {
            $0.function = "f"
            $0.interaction = 1
        })
    /// A dialog's button that sends its inputs.
    static let submit = Wire.encoded(Dynamite_CardAction.with { $0.function = "g" })
    static func text(_ string: String) -> Dynamite_FormattedText {
        .with { $0.segments = [.with { $0.run.text = string }] }
    }
    /// A dialog card: a header, a text field, and a footer with two buttons.
    static let dialog = Dynamite_Card.with { card in
        card.header.title = text("T")
        card.sections = [
            .with {
                $0.widgets = [
                    .with {
                        $0.textInput = .with {
                            $0.name = "a"
                            $0.label = "A"
                        }
                    }
                ]
            }
        ]
        card.fixedFooter.primaryButton = .with {
            $0.label = text("P")
            $0.type = 2
            $0.onClick.action = submit
        }
        card.fixedFooter.secondaryButton = .with {
            $0.label = text("S")
            $0.onClick.action = submit
        }
    }
}
