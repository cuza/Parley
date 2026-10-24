import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

/// A mention of someone who isn't a member, as Google Chat sends it: INVITE adds them where I may add people to a space
/// or group; REFERENCE only names them in a 1:1 DM or without that right. Undecided until the member list is known.
@MainActor struct OutsiderMentionTests {
    static let wu = TextStyleRange(style: .mention(userID: "w"), start: 0, length: 3)
    static let plato = TextStyleRange(style: .mention(userID: "p"), start: 4, length: 6)
    static let members = [Person(id: "p", name: "Plato")]
    @Test func aNonMemberIsInvitedOnlyWhereIMayAddPeople() {
        #expect(
            ChatStore.outsiders([Self.wu, Self.plato], members: Self.members, kind: .space, canAdd: true) == [
                "w": .invite
            ])
        #expect(ChatStore.outsiders([Self.wu], members: Self.members, kind: .group, canAdd: true) == ["w": .invite])
        #expect(ChatStore.outsiders([Self.wu], members: Self.members, kind: .space, canAdd: false) == ["w": .reference])
        #expect(ChatStore.outsiders([Self.wu], members: Self.members, kind: .direct, canAdd: true) == ["w": .reference])
        #expect(ChatStore.outsiders([Self.wu], members: nil, kind: .space, canAdd: true).isEmpty)
        let all = TextStyleRange(style: .mention(userID: TextStyleRange.everyone), start: 0, length: 4)
        #expect(ChatStore.outsiders([all], members: [], kind: .space, canAdd: true).isEmpty)
    }
    @Test func theirMentionGoesAsInviteOrReference() throws {
        let sent = DynamiteMapper.annotations([Self.wu, Self.plato], outsiders: ["w": .invite])
        #expect(sent.map(\.userMentionMetadata.type) == [.invite, .mention])
        #expect(
            sent[0].userMentionMetadata.inviteeInfo.userID.id == "w" && sent[0].userMentionMetadata.id.type == .human)
        #expect(
            DynamiteMapper.annotations([Self.wu], outsiders: ["w": .reference]).first?.userMentionMetadata.type
                == .reference)
    }
}
