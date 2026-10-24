import Foundation
import ParleyDomain
import os

/// One call to Google Contacts' widget service, the one behind the person card and detailed view in Google Chat. A new
/// capability is a new type conforming to this; `GoogleContacts` sends any of them.
protocol ContactsRequest: Sendable {
    associatedtype Reply: Sendable
    /// The call's id in the batch.
    static var rpc: String { get }
    /// Every argument, as the call takes them; `build` is the widget page's build label, which some calls carry.
    func arguments(build: String) -> [Any]
    /// Reads the call's answer, the JSON its batch entry carries.
    func reply(_ payload: Any) throws -> Reply
}

/// Sends `ContactsRequest`s as Google Chat's detailed view does: a batch call on contacts.google.com with the session's
/// cookies and the widget page's own token, read from the page once and again when a call is refused.
actor GoogleContacts {
    static let host = "contacts.google.com"
    static let pageURL = URL(
        string: "https://contacts.google.com/widget/companion?origin=https://chat.google.com&hl=en")!
    /// What a call needs from the widget page: its token (`at`), its session id and its build label.
    struct Page: Equatable, Sendable {
        let token: String
        let session: String
        let build: String
    }

    private let authorizer: WebSessionAuthorizer
    private var loading: Task<Page, any Error>?
    private var requestID = Int.random(in: 1000...9999)
    private let log = Logger(subsystem: "dev.cuza.Parley", category: "google")
    init(authorizer: WebSessionAuthorizer) { self.authorizer = authorizer }

    func send<Request: ContactsRequest>(_ request: Request) async throws -> Request.Reply {
        for attempt in 0...1 {
            let page = try await page(fresh: attempt > 0)
            requestID += 100_000
            do {
                let (data, _) = try await authorizer.data(for: Self.urlRequest(request, page: page, id: requestID))
                log.info("contacts \(Request.rpc, privacy: .public): \(data.count, privacy: .public) bytes")
                if let payload = try Self.payload(Request.rpc, in: data) { return try request.reply(payload) }
                log.notice(
                    "contacts \(Request.rpc, privacy: .public) answered without a result: reading the page again")
            } catch AuthFailure.http(let status) where attempt == 0 && [400, 401, 403].contains(status) {
                log.notice(
                    "contacts \(Request.rpc, privacy: .public) refused (\(status, privacy: .public)): reading the page again"
                )
            }
        }
        throw GoogleServiceError.unexpectedReply
    }

    /// The widget page's values, loaded once for every caller; `fresh` loads it again.
    private func page(fresh: Bool) async throws -> Page {
        if fresh { loading = nil }
        let task =
            loading
            ?? Task { [authorizer] in
                let (data, _) = try await authorizer.data(for: URLRequest(url: Self.pageURL))
                guard let page = Self.page(String(decoding: data, as: UTF8.self)) else {
                    throw GoogleServiceError.unexpectedReply
                }
                return page
            }
        loading = task
        do { return try await task.value } catch {
            if loading == task { loading = nil }
            throw error
        }
    }
    static func page(_ html: String) -> Page? {
        guard let token = WebSessionAuthorizer.pageValue("SNlM0e", in: html),
            let session = WebSessionAuthorizer.pageValue("FdrFJe", in: html),
            let build = WebSessionAuthorizer.pageValue("cfb2h", in: html)
        else { return nil }
        return Page(token: token, session: session, build: build)
    }

    static func urlRequest<Request: ContactsRequest>(_ request: Request, page: Page, id: Int) throws -> URLRequest {
        var components = URLComponents(string: "https://\(host)/_/PeopleCompanionUi/data/batchexecute")!
        components.queryItems = [
            ("rpcids", Request.rpc), ("source-path", "/widget/companion"), ("f.sid", page.session), ("bl", page.build),
            ("hl", "en"), ("soc-app", "758"), ("soc-platform", "1"), ("soc-device", "1"), ("_reqid", "\(id)"),
            ("rt", "c"),
        ]
        .map { URLQueryItem(name: $0.0, value: $0.1) }
        let arguments = String(
            decoding: try JSONSerialization.data(withJSONObject: request.arguments(build: page.build)), as: UTF8.self)
        let batch = String(
            decoding: try JSONSerialization.data(withJSONObject: [[[Request.rpc, arguments, NSNull(), "generic"]]]),
            as: UTF8.self)
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data("f.req=\(formEncoded(batch))&at=\(formEncoded(page.token))&".utf8)
        urlRequest.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("1", forHTTPHeaderField: "X-Same-Domain")
        return urlRequest
    }
    /// Everything but unreserved characters escaped, so "&", "=" and "+" in a name stay part of its value.
    static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }
    /// The result of `rpc` in a batch answer: after the ")]}'" guard, lines of JSON whose entries read
    /// `["wrb.fr", rpc, "<result as JSON>", …]`. Nil when the batch carries none (an entry with an error instead).
    static func payload(_ rpc: String, in data: Data) throws -> Any? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("[") {
            guard let entries = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any] else { continue }
            for case let entry as [Any] in entries
            where entry.count > 2 && entry[0] as? String == "wrb.fr" && entry[1] as? String == rpc {
                guard let result = entry[2] as? String else { return nil }
                return try JSPB.parse(Data(result.utf8))
            }
        }
        return nil
    }
}

/// A person's job title, as Google Chat's person card shows it; asked by email, with their name as a hint.
struct ContactCard: ContactsRequest {
    static let rpc = "wiDBGd"
    let email: String
    let name: String
    func arguments(build: String) -> [Any] {
        [[[3, 3, "1", 359]], [NSNull(), NSNull(), NSNull(), email], [1, 5, 4, 2], [name, email]]
    }
    /// `[1, person]`; the person's field 16 holds `[title, …]`.
    func reply(_ payload: Any) throws -> String? {
        guard let title = JSPB.field(JSPB.field(JSPB.field(payload, 2), 16), 1) as? String, !title.isEmpty else {
            return nil
        }
        return title
    }
}

/// The detailed view's calls start with this header, its build label included.
private func companionHeader(_ build: String) -> [Any] { [[4, 3, build, 5]] }
private func who(_ id: PersonID) -> [Any] { [NSNull(), NSNull(), id.rawValue] }
private func date(_ seconds: Any?) -> Date? {
    (seconds as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
}

/// Who reports to a person and whom they report to, as the detailed view's Reports section shows them.
struct ContactReports: ContactsRequest {
    static let rpc = "aeNYre"
    let id: PersonID
    let email: String?
    func arguments(build: String) -> [Any] {
        [companionHeader(build), who(id), email.map { [$0] } ?? [], NSNull(), NSNull(), 100, [1, NSNull(), 1, 0]]
    }
    /// `[[?, [reports], "", count, ?, [[managers], self]]]`; each person `[name, id, photo, title]`.
    func reply(_ payload: Any) throws -> PersonDetails {
        let entry = JSPB.field(payload, 1)
        func people(_ list: Any?) -> [PersonDetails.Colleague] {
            (list as? [Any] ?? []).compactMap { person in
                guard let name = JSPB.field(person, 1) as? String, let id = JSPB.field(person, 2) as? String,
                    !id.isEmpty
                else { return nil }
                return .init(
                    id: PersonID(id), name: name,
                    avatarURL: (JSPB.field(person, 3) as? String).flatMap(URL.init(string:)),
                    title: (JSPB.field(person, 4) as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        let reports = people(JSPB.field(entry, 2))
        return PersonDetails(
            reports: reports, reportCount: max((JSPB.field(entry, 4) as? Int) ?? 0, reports.count),
            managers: people(JSPB.field(JSPB.field(entry, 6), 1)))
    }
}

/// Calendar events and Gmail threads I recently shared with a person, newest first, as the Recent interactions section.
struct ContactRecent: ContactsRequest {
    static let rpc = "PaMnxe"
    let id: PersonID
    let email: String?
    func arguments(build: String) -> [Any] { [companionHeader(build), who(id), 15, [1, 2], email.map { [$0] } ?? []] }
    /// `[[[[kind, url, title, null, flags, [seconds], [null, title as HTML]], …]]]`; kind 1 an event, 2 an email thread.
    func reply(_ payload: Any) throws -> [PersonDetails.Item] {
        (JSPB.field(JSPB.field(payload, 1), 1) as? [Any] ?? []).compactMap { item in
            guard let kind = JSPB.field(item, 1) as? Int, kind == 1 || kind == 2,
                let url = (JSPB.field(item, 2) as? String).flatMap(URL.init(string:)),
                let title = JSPB.field(item, 3) as? String
            else { return nil }
            return .init(
                kind: kind == 1 ? .event : .email, title: title, url: url,
                date: date(JSPB.field(JSPB.field(item, 6), 1)))
        }
    }
}

/// Drive files a person shared with me, as the Shared files section, and Drive's search for more of them.
struct ContactFiles: ContactsRequest {
    static let rpc = "mVTqH"
    let id: PersonID
    func arguments(build: String) -> [Any] { [companionHeader(build), who(id)] }
    /// `[[[title, url, icon, [seconds, nanos]], …], drive search url]`.
    func reply(_ payload: Any) throws -> PersonDetails {
        let files: [PersonDetails.Item] = (JSPB.field(payload, 1) as? [Any] ?? []).compactMap { file in
            guard let title = JSPB.field(file, 1) as? String,
                let url = (JSPB.field(file, 2) as? String).flatMap(URL.init(string:))
            else { return nil }
            return .init(kind: .file, title: title, url: url, date: date(JSPB.field(JSPB.field(file, 4), 1)))
        }
        return PersonDetails(files: files, moreFiles: (JSPB.field(payload, 2) as? String).flatMap(URL.init(string:)))
    }
}
