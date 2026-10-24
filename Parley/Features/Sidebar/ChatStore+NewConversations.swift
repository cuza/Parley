import Foundation
import ParleyDomain

extension ChatStore {
    /// Nothing announces a new invitation, so the directory is read again this often while Parley is in front.
    static let invitationsTTL: TimeInterval = 300
    /// Reads invitations from the space directory, at most once per `invitationsTTL` unless forced. A failed read keeps the last list.
    func refreshInvitations(force: Bool = false) async {
        guard rooms.invitationsDue(at: now(), ttl: Self.invitationsTTL, force: force) else { return }
        rooms.invitationsFetched = now()
        // ponytail: the directory's first page only; page through it if invitations past it go missing.
        guard let listed = try? await backend.searchSpaces(matching: "") else { return }
        let inSidebar = Set(rooms.conversations.map(\.id))
        rooms.invitations = listed.filter { $0.invited && !inSidebar.contains($0.id) }
    }
    // New conversations. Errors stay with the caller, which shows them where the search or action happened.
    func searchPeople(matching query: String) async throws -> [Person] {
        try await backend.searchPeople(matching: query)
    }
    func searchSpaces(matching query: String) async throws -> [SpaceListing] {
        try await backend.searchSpaces(matching: query)
    }
    /// Opens the DM with exactly these people: the sidebar's when there is one, else the server's (found or created).
    func message(_ people: [Person]) async throws {
        let ids = Set(people.map(\.id)).subtracting([me.id])
        guard !ids.isEmpty else { return }
        if let room = rooms.conversations.first(where: {
            $0.kind != .space && Set($0.members.map(\.id)).subtracting([me.id]) == ids
        }) {
            await select(room.id)
            return
        }
        await open(try await backend.directMessage(with: people.map(\.id).filter { $0 != me.id }))
    }
    /// Joins a space, or just opens it when it is already in the sidebar.
    func join(_ space: SpaceListing) async throws {
        if rooms.conversations.contains(where: { $0.id == space.id }) {
            await select(space.id)
            return
        }
        await open(try await backend.join(space))
        rooms.invitations.removeAll { $0.id == space.id }
    }
    /// A new space with me in it, opened at once; Google Chat asks for a name only. Errors stay with the caller's sheet.
    func createSpace(name: String, emoji: String?) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NewSpaceError.noName }
        await open(try await backend.createSpace(name: name, emoji: emoji))
    }
    enum NewSpaceError: LocalizedError {
        case noName
        var errorDescription: String? { "A space needs a name." }
    }
    /// Off the sidebar at once; a refusal puts it back.
    func deleteSpace(_ id: ConversationID) async {
        await removeFromSidebar(id, refusal: .alert) { try await self.backend.deleteSpace(id) }
    }
    private func open(_ room: Conversation) async {
        apply(.conversationUpserted(room))
        await select(room.id)
    }
}
