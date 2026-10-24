import AppKit
import Foundation
import SwiftProtobuf
import SwiftUI
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// System lines and Gemini sources: an admin's membership change, a source's snippet.
struct AnnotationExtrasTests {
    @Test func anAdminsMembershipChangeIsNotNamed() {
        let proto = Dynamite_Message.with { built in
            built.creator.userID.id = "u1"
            built.annotations = [
                .with {
                    $0.membershipChanged = .with { change in
                        change.type = .added
                        change.initiator.id = "u1"
                        change.initiatorType = 2
                        change.affectedMembers = [.with { $0.userID.id = "u2" }]
                    }
                }
            ]
        }
        let people = ["u1": Person(id: "u1", name: "Ana"), "u2": Person(id: "u2", name: "Ben")]
        #expect(DynamiteMapper.systemText(proto, in: "space/s", selfID: "me", people: people) == "An admin added Ben")
    }
    @Test func aSourcesSnippetIsItsDetail() {
        let source = Dynamite_ContextSource.with {
            $0.title = "T"
            $0.url = "https://example.com"
            $0.snippet.text = "S"
            $0.footer.text = "F"
        }
        let annotation = Dynamite_Annotation.with { $0.contextSourceMetadata.sources = [source] }
        #expect(DynamiteMapper.sources([annotation]).first?.detail == "S")
        var footer = source
        footer.clearSnippet()
        #expect(DynamiteMapper.sources([.with { $0.contextSourceMetadata.sources = [footer] }]).first?.detail == "F")
    }
}
