import Foundation

@testable import ParleyData
@testable import ParleyDomain

/// The people and messages the mapper suites build, as Google Chat sends them.
protocol MapperFixtures {}

extension MapperFixtures {
    var people: [String: Person] {
        [
            "me": Person(id: "me", name: "Dave"), "u1": Person(id: "u1", name: "Maria"),
            "u2": Person(id: "u2", name: "Alex"),
        ]
    }
    func msg(
        _ id: String, topic: String = "t1", by user: String = "u1", at micros: Int64 = 1_000_000, text: String = "hi"
    ) -> Dynamite_Message {
        .with {
            $0.id.parentID.topicID.topicID = topic
            $0.id.messageID = id
            $0.creator.userID.id = user
            $0.createTime = micros
            $0.textBody = text
        }
    }
}
