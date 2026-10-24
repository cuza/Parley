import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// Read-only cards: an app or integration message's card becomes formatted text in its bubble.
struct CardTests: CardMessageFixtures {
    /// As Google Chat shows a Drive notice: the notice text in the bubble, and under it the card, a section at a time:
    /// the file row (opening the file), the comment, the author with their avatar, then only the buttons that open a link.
    @Test func aDriveNoticeKeepsItsTextAndShowsItsCard() throws {
        let avatar = "https://lh3.example.com/a/photo"
        let card = Dynamite_Card.with { built in
            built.sections = [
                .with {
                    $0.widgets = [
                        .with {
                            $0.decoratedText = .with {
                                $0.text = text("Plan")
                                $0.onClick = link("https://docs.example.com/d/1")
                                $0.icon = .with { $0.url = "https://www.gstatic.com/docs.png" }
                            }
                        }
                    ]
                },
                .with {
                    $0.widgets = [.with { $0.textParagraph = .with { $0.text = text("Looks good", italic: true) } }]
                },
                .with {
                    $0.widgets = [
                        .with {
                            $0.decoratedText = .with {
                                $0.topLabel = text("Alex (alex@example.com)")
                                $0.text = text("Agreed")
                                $0.icon = .with {
                                    $0.url = avatar
                                    $0.imageType = 2
                                }
                            }
                        }
                    ]
                },
                .with {
                    $0.widgets = [
                        .with {
                            $0.columns = .with {
                                $0.columns = [
                                    .with {
                                        $0.widgets = [
                                            .with {
                                                $0.buttons = [
                                                    .with {
                                                        $0.textButton = .with {
                                                            $0.label = text("Reply")
                                                            $0.onClick = .with { $0.action = Data([1]) }
                                                        }
                                                    },
                                                    .with {
                                                        $0.textButton = .with {
                                                            $0.label = text("Open")
                                                            $0.onClick = link("https://docs.example.com/d/1")
                                                        }
                                                    },
                                                ]
                                            }
                                        ]
                                    }
                                ]
                            }
                        }
                    ]
                },
            ]
        }
        var proto = message(card: card, body: "Alex mentioned you in Plan")
        proto.annotations = [
            .with { annotation in
                annotation.type = .driveDoc
                annotation.startIndex = 22
                annotation.length = 4
                annotation.driveMetadata.title = "Plan"
            }
        ]
        let shown = try mapped(proto)
        #expect(shown.text == "Alex mentioned you in Plan")
        #expect(shown.attachments.count == 1)  // the card; the file is in it, not in a second chip
        let drawn = try #require(shown.attachments.first?.card)
        let file = URL(string: "https://docs.example.com/d/1")!
        #expect(
            drawn.sections == [
                // one line; the row opens the file, its text no link
                [
                    .row(
                        icon: URL(string: "https://www.gstatic.com/docs.png"), round: false, label: nil, text: "Plan",
                        formatting: [TextStyleRange(style: .nowrap, start: 0, length: 4)], open: file)
                ],
                [.text("Looks good", [TextStyleRange(style: .italic, start: 0, length: 10)])],
                [
                    .row(
                        icon: URL(string: avatar), round: true, label: "Alex (alex@example.com)", text: "Agreed",
                        formatting: [TextStyleRange(style: .nowrap, start: 0, length: 6)])
                ],
                // Reply sends an action to the app: it opens the message in Google Chat, where that works.
                [
                    .links([
                        Card.Link(title: "Reply", url: ChatLink.url(message: shown.id)!),
                        Card.Link(title: "Open", url: file),
                    ])
                ],
            ])
        #expect(shown.attachments.first?.name == "Plan")  // what Home and notifications summarise it as
    }
    /// An app's welcome message in its DM: the text, and a card whose only button opens the app's dialog ("Sign in"):
    /// it carries its action, marked as a dialog's, with the message in Google Chat as its link.
    @Test func aDialogButtonCarriesItsAction() throws {
        let card = Dynamite_Card.with {
            $0.sections = [
                .with {
                    $0.widgets = [
                        .with {
                            $0.buttons = [
                                .with {
                                    $0.textButton = .with {
                                        $0.label = text("Sign in")
                                        $0.onClick = .with {
                                            $0.action = Data([10, 4, 0x6C, 0x69, 0x73, 0x74, 0x40, 1])
                                        }
                                    }
                                }  // interaction 1: a dialog
                            ]
                        }
                    ]
                }
            ]
        }
        let shown = try mapped(message(card: card, body: "Connect your account. To get started, click *Sign in*."))
        #expect(
            shown.attachments.first?.card?.sections == [
                [
                    .links([
                        Card.Link(
                            title: "Sign in", url: ChatLink.url(message: shown.id)!,
                            action: Data([10, 4, 0x6C, 0x69, 0x73, 0x74, 0x40, 1]), dialog: true)
                    ])
                ]
            ])
    }
    /// A link an app in the space previews: its card in web's small type (the row's bottom label small and grey, the
    /// description cut to the lines the card asks for), and under it the app that made it ("By <app>", an App badge).
    @Test func anAppLinkPreviewIsSmallAndSaysWhichAppMadeIt() throws {
        let card = Dynamite_Card.with {
            $0.sections = [
                .with {
                    $0.widgets = [
                        .with {
                            $0.decoratedText = .with {
                                $0.text = text("owner/repo")
                                $0.onClick = link("https://example.com/owner/repo")
                                $0.bottomLabel = text("Updated: today")
                            }
                        },
                        .with {
                            $0.textParagraph = .with {
                                $0.text = text("A long description")
                                $0.maxLines = 2
                            }
                        },
                    ]
                }
            ]
        }
        var proto = message(card: card, body: "https://example.com/owner/repo")
        proto.appAttachments[0].app.userID.id = "app1"
        let icon = URL(string: "https://example.com/app.png")!
        let people = ["app1": Person(id: "app1", name: "Example", avatarURL: icon)]
        let shown = try #require(DynamiteMapper.message(proto, in: "dm/d", selfID: "me", people: people))
        let drawn = try #require(shown.attachments.first?.card)
        #expect(
            drawn.sections == [
                [
                    .row(
                        icon: nil, round: false, label: nil, text: "owner/repo\nUpdated: today",
                        formatting: [
                            TextStyleRange(style: .nowrap, start: 0, length: 10),
                            TextStyleRange(style: .small, start: 11, length: 14),
                            TextStyleRange(style: .color(Card.secondaryText), start: 11, length: 14),
                        ],
                        open: URL(string: "https://example.com/owner/repo")),
                    .text("A long description", [], lines: 2),
                ]
            ])
        #expect(drawn.by == Card.Attribution(name: "Example", icon: icon))
        #expect(try mapped(proto).attachments.first?.card?.by == nil)  // an app not looked up yet: no byline
        #expect(
            CardLayout.size(drawn, maxWidth: 400).height == CardLayout.size(
                Card(sections: drawn.sections), maxWidth: 400
            ).height + CardLayout.gap + CardLayout.byline)
        #expect(
            NativeMessageText.size(
                of: "Updated", formatting: [TextStyleRange(style: .small, start: 0, length: 7)], width: 300
            ).width
                < NativeMessageText.size(of: "Updated", width: 300).width)
    }
    /// Google sends a YouTube link with no title or picture and "do not render", and Google Chat shows a card anyway:
    /// "YouTube video" with the video's thumbnail and a play button.
    @Test func aYouTubeLinkGetsAVideoCard() throws {
        for (link, id) in [
            ("https://www.youtube.com/watch?v=abcDEF12345&t=3", "abcDEF12345"),
            ("https://youtu.be/abcDEF12345", "abcDEF12345"),
        ] {
            let message = Dynamite_Message.with { built in
                built.id.messageID = "m4"
                built.id.parentID.topicID.topicID = "m4"
                built.creator.userID.id = "u1"
                built.textBody = "Watch the video below."
                built.annotations = [
                    .with { annotation in
                        annotation.type = .url
                        annotation.startIndex = 10
                        annotation.length = 5
                        annotation.urlMetadata = .with {
                            $0.url.url = link
                            $0.domain = "www.youtube.com"
                            $0.shouldNotRender = true
                            $0.urlSource = .richText
                        }
                    }
                ]
            }
            let video = try #require(try mapped(message).attachments.first)
            #expect(
                video.kind == .link && video.name == "YouTube video" && video.domain == "youtube.com"
                    && video.isVideoLink)
            #expect(
                video.thumbnailURL == URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
                    && video.url == URL(string: link))
        }
    }
    /// An app's card can carry the same id as Gemini's feedback row ("accessory_actions"): a reminder's "Manage
    /// reminder" button. It shows, opening the app's dialog.
    @Test func anAccessoryCardWithATextButtonIsShown() throws {
        let card = Dynamite_Card.with {
            $0.sections = [
                .with {
                    $0.widgets = [
                        .with {
                            $0.buttons = [
                                .with {
                                    $0.textButton = .with {
                                        $0.label = text("Manage reminder")
                                        $0.onClick = .with { $0.action = Data([10, 1, 0x65, 0x40, 1]) }
                                    }
                                }
                            ]
                        }
                    ]
                }
            ]
        }  // a dialog, as the reminder's is
        let shown = try mapped(message(card: card, body: "Scheduled reminder", id: "accessory_actions"))
        #expect(
            shown.attachments.first?.card?.sections == [
                [
                    .links([
                        Card.Link(
                            title: "Manage reminder", url: ChatLink.url(message: shown.id)!,
                            action: Data([10, 1, 0x65, 0x40, 1]), dialog: true)
                    ])
                ]
            ])
    }
    @Test func geminisFeedbackRowIsNotShown() throws {
        let feedback = Dynamite_Card.with {
            $0.sections = [.with { $0.widgets = [.with { $0.buttons = [.init(), .init()] }] }]
        }  // icon-only buttons
        let shown = try mapped(message(card: feedback, body: "Here is the answer.", id: "accessory_actions"))
        #expect(shown.text == "Here is the answer." && shown.attachments.isEmpty)
    }
    @Test func aMessageWithNothingToShowSaysSo() throws {
        let shown = try mapped(message(card: Dynamite_Card(), body: ""))
        #expect(shown.text == "Unsupported message")
    }
}

/// Content Parley can't draw yet is never dropped: it shows as "Unsupported message" with a link to it in Google Chat.
/// A system event Parley can't word stays hidden, as web shows none.
struct UnsupportedContentTests {
    private func message(_ configure: (inout Dynamite_Message) -> Void) -> Dynamite_Message {
        .with { proto in
            proto.id.messageID = "u1"
            proto.id.parentID.topicID.topicID = "t1"
            proto.creator.userID.id = "alex"
            proto.messageType = .userMessage
            configure(&proto)
        }
    }
    private func shown(_ proto: Dynamite_Message) -> Message? {
        DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:])
    }

    @Test func aCalendarChipWithNoTextOffersToOpenIt() throws {
        let calendar = message {
            $0.annotations = [
                .with {
                    $0.type = .gsuiteIntegration
                    $0.chipRenderType = .render
                    $0.gsuiteIntegrationMetadata = .with { _ in }
                }
            ]
        }
        let shown = try #require(self.shown(calendar))
        #expect(!shown.isSystem && shown.text == "Unsupported message")
        let open = try #require(shown.attachments.first)
        #expect(
            open.name == "Open in Google Chat" && open.url?.host() == "chat.google.com"
                && open.url?.path().hasSuffix("/t1/u1") == true)
    }
    @Test func aCardOfPartsParleyDoesNotDrawOffersToOpenIt() throws {
        let card = message {
            $0.appAttachments = [
                .with {
                    $0.card = .with { $0.sections = [.with { $0.widgets = [.with { _ in }] }] }
                    $0.attachmentID = "c"
                }
            ]
        }
        let shown = try #require(self.shown(card))
        #expect(shown.text == "Unsupported message" && shown.attachments.first?.name == "Open in Google Chat")
    }
    @Test func aSystemEventParleyCannotWordStaysHidden() {
        let event = message {
            $0.messageType = .systemMessage
            $0.annotations = [.with { $0.type = .membershipChanged }]
        }
        #expect(shown(event) == nil)
    }
}
