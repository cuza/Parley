import Foundation
import ParleyDomain

extension DynamiteBackend {
    /// Dynamite has no directory-wide people search (the official apps ask a separate people service), so this searches everyone
    /// Parley has looked up: sidebar members, senders and member lists. An email address can always be invited.
    public func searchPeople(matching query: String) async throws -> [Person] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = people.values.filter { person in
            person.id.rawValue != selfID && person.name != "Unknown"
                && (query.isEmpty || person.name.localizedCaseInsensitiveContains(query)
                    || person.email?.localizedCaseInsensitiveContains(query) == true)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let isEmail = query.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
        guard isEmail, !known.contains(where: { $0.email?.caseInsensitiveCompare(query) == .orderedSame }) else {
            return known
        }
        return known + [Person.invite(email: query)]
    }
    /// Someone to invite: by id (with the email when known), or by email only.
    func invitee(_ id: PersonID) -> Dynamite_InviteeInfo {
        .with {
            if let email = Person.invitedEmail(id) {
                $0.email = email
                $0.invitationMode = 2
            }  // EMAIL_ONLY
            else {
                $0.userID.id = id.rawValue
                $0.invitationMode = 1  // GAIA_ID
                if let email = people[id.rawValue]?.email { $0.email = email }
            }
        }
    }
    public func searchDriveFiles(matching query: String) async throws -> [DriveFile] {
        let files = try await google.send(DriveSuggestions(query: query))
        log.info(
            "drive suggestions: \(files.count, privacy: .public) for a query of \(query.count, privacy: .public) characters"
        )
        return files
    }
    public func searchDirectory(matching query: String) async throws -> [Person] {
        guard !query.isEmpty else { return [] }  // Google answers "@" alone with nothing
        let people = try await google.send(PeopleAutocomplete(query: query))
        log.info(
            "directory people: \(people.count, privacy: .public) for a query of \(query.count, privacy: .public) characters"
        )
        return people
    }
    public func timeZone(email: String) async throws -> TimeZone? {
        try await google.send(PersonTimeZone(email: email))
    }
    public func jobTitle(email: String, name: String) async throws -> String? {
        try await contacts.send(ContactCard(email: email, name: name))
    }
    /// The detailed view's three parts, asked together; one that fails leaves its section out.
    public func personDetails(id: PersonID, email: String?) async throws -> PersonDetails {
        async let reports = try? contacts.send(ContactReports(id: id, email: email))
        async let recent = try? contacts.send(ContactRecent(id: id, email: email))
        async let files = try? contacts.send(ContactFiles(id: id))
        let (line, shared, theirs) = await (reports, recent, files)
        guard line != nil || shared != nil || theirs != nil else { throw GoogleServiceError.unexpectedReply }
        var details = line ?? PersonDetails()
        details.recent = shared ?? []
        details.files = theirs?.files ?? []
        details.moreFiles = theirs?.moreFiles
        let counts =
            "\(details.reports.count) reports, \(details.managers.count) managers, \(details.recent.count) recent, \(details.files.count) files"
        log.info("person details: \(counts, privacy: .public)")
        return details
    }
}
