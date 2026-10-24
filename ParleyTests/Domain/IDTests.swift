import Foundation
import Testing

@testable import ParleyDomain

/// Ids are typed in code but stored as the plain strings they always were: caches, drafts and settings written by
/// earlier builds read the same, and new ones read in earlier builds.
struct IDTests {
    @Test func eachKindIsAPlainJSONString() throws {
        try roundTrip(ConversationID("space/a"), "space/a")
        try roundTrip(MessageID("space/a/t1/m1"), "space/a/t1/m1")
        try roundTrip(ThreadID("space/a/t1/t1"), "space/a/t1/t1")
        try roundTrip(PersonID("123"), "123")
    }
    @Test func asADictionaryKeyItIsAPlainStringKey() throws {
        let encoded = try JSONEncoder().encode([ConversationID("space/a"): 1])
        #expect(try JSONDecoder().decode([String: Int].self, from: encoded) == ["space/a": 1])
        #expect(try JSONDecoder().decode([ConversationID: Int].self, from: Data(#"{"dm/b":2}"#.utf8)) == ["dm/b": 2])
    }
    @Test func itPrintsAsItsString() {
        let id = MessageID("space/a/t1/m1")
        #expect("\(id)" == "space/a/t1/m1" && String(reflecting: id) == String(reflecting: "space/a/t1/m1"))
    }
    /// A launch cache as builds wrote it while ids were strings: every id, in every place one is kept, reads back.
    @Test func aCacheWrittenBeforeTypedIDsReadsTheSame() throws {
        let alex = #"{"id":"alex","name":"Alex","presence":"offline"}"#
        let me = #"{"id":"me","name":"Me","presence":"offline"}"#
        let head =
            #"{"id":"space/a/t1/t1","conversationID":"space/a","sender":\#(alex),"text":"@Me hi","createdAt":0,"edited":false,"#
            + #""reactions":[{"emoji":"👍","people":["me","alex"]}],"delivery":"sent","replyCount":1,"#
            + #""formatting":[{"style":{"mention":{"userID":"me"}},"start":0,"length":3}]}"#
        let reply =
            #"{"id":"space/a/t1/r1","conversationID":"space/a","threadID":"space/a/t1/t1","sender":\#(me),"text":"yes","#
            + #""createdAt":10,"edited":false,"reactions":[],"delivery":"sent","replyCount":0}"#
        let json =
            #"{"accountID":"me","selectedID":"space/a","#
            + #""conversations":[{"id":"space/a","name":"Design","kind":"space","members":[\#(alex)],"unread":0,"pinned":false,"muted":false}],"#
            + #""messages":[\#(head),\#(reply)],"drafts":{"space/a/space/a/t1/t1":"unsent reply"},"#
            + #""serverDrafts":{"space/a/space/a/t1/t1":{"id":"d1","conversationID":"space/a","threadID":"space/a/t1/t1","text":"unsent reply","#
            + #""formatting":[],"updatedAt":0}},"#
            + #""homeThreads":[{"id":"space/a/t1/t1","conversationID":"space/a","head":\#(head),"latest":\#(reply),"unread":true,"time":10}]}"#
        let snapshot = try JSONDecoder().decode(LaunchSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.accountID == "me" && snapshot.selectedID == "space/a")
        #expect(
            snapshot.conversations.map(\.id) == ["space/a"]
                && snapshot.conversations.first?.members.map(\.id) == ["alex"])
        #expect(
            snapshot.messages.map(\.id) == ["space/a/t1/t1", "space/a/t1/r1"]
                && snapshot.messages.map(\.conversationID) == ["space/a", "space/a"])
        #expect(
            snapshot.messages.last?.threadID == "space/a/t1/t1"
                && snapshot.messages.first?.reactions.first?.people == ["me", "alex"])
        #expect(snapshot.messages.first?.formatting.first?.style == .mention(userID: "me"))
        #expect(snapshot.drafts == ["space/a/space/a/t1/t1": "unsent reply"])
        #expect(snapshot.serverDrafts.first?.value.threadID == "space/a/t1/t1")
        #expect(
            snapshot.homeThreads.map(\.id) == ["space/a/t1/t1"] && snapshot.homeThreads.first?.latest.sender.id == "me")
    }

    private func roundTrip<Tag>(_ id: ID<Tag>, _ text: String) throws {
        let encoded = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(String.self, from: encoded) == text)
        #expect(try JSONDecoder().decode(ID<Tag>.self, from: JSONEncoder().encode(text)) == id)
    }
}
