import CryptoKit
import Foundation
import OSLog
import ParleyDomain
import Security

/// Signing in and the session's health, for the session here and the sign-in views.
public let authLog = Logger(subsystem: "dev.cuza.Parley", category: "auth")

extension SessionCookie {
    func applies(to url: URL, now: Date = .now) -> Bool {
        guard let host = url.host?.lowercased(), !name.isEmpty, !value.isEmpty,
            !name.contains(where: { $0.isWhitespace || "=;\r\n".contains($0) }),
            !value.contains(where: { ";\r\n".contains($0) }),
            expires <= 0 || expires > now.timeIntervalSince1970,
            !secure || url.scheme == "https"
        else { return false }
        let domain = domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard bare == "google.com" || bare == "chat.google.com" else { return false }
        guard host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare)) else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = path.isEmpty ? "/" : path
        return requestPath == cookiePath
            || (requestPath.hasPrefix(cookiePath)
                && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"))
    }
    static func header(_ cookies: [Self], for url: URL, now: Date = .now) -> String {
        cookies.filter { $0.applies(to: url, now: now) }
            .sorted { $0.path.count == $1.path.count ? $0.name < $1.name : $0.path.count > $1.path.count }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    /// Applies a response's `Set-Cookie` headers the way a browser jar would: same name, domain and path is
    /// updated in place, an expired one is removed, a new one is appended. Domains other than google.com and
    /// chat.google.com are never stored.
    static func merging(_ cookies: [Self], from response: HTTPURLResponse) -> [Self] {
        guard let url = response.url, response.value(forHTTPHeaderField: "Set-Cookie") != nil,
            let fields = response.allHeaderFields as? [String: String]
        else { return cookies }
        var merged = cookies
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let domain = cookie.domain.lowercased()
            guard [".google.com", "chat.google.com", ".chat.google.com"].contains(domain) else { continue }
            let index = merged.firstIndex {
                $0.name == cookie.name && $0.domain.lowercased() == domain && $0.path == cookie.path
            }
            // Max-Age=0 parses as an expiry of "now", so allow a second of slack.
            if let expiry = cookie.expiresDate, expiry.timeIntervalSinceNow < 1 {
                if let index { merged.remove(at: index) }
                continue
            }
            let updated = SessionCookie(
                name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                secure: cookie.isSecure, expires: cookie.expiresDate?.timeIntervalSince1970 ?? -1)
            if let index {
                // A Max-Age cookie re-sent with the same value only slides its expiry; skip that so it is not a Keychain write per response.
                let current = merged[index]
                if current.value == updated.value, current.secure == updated.secure, current.expires > 0,
                    abs(current.expires - updated.expires) < 86_400
                {
                    continue
                }
                merged[index] = updated
            } else {
                merged.append(updated)
            }
        }
        return merged
    }
}

public struct KeychainSessionVault: SessionVault {
    // Xcode's Debug builds keep their own session: an entry saved by one signature locks the other build out of it,
    // so a Debug build and the installed app running side by side would keep signing each other out.
    // What an installed copy reads after an update: change these only with a migration (a test pins them).
    static let releaseService = "dev.cuza.Parley", debugService = "dev.cuza.Parley.debug",
        account = "dynamite.web-session"
    #if DEBUG
        var service = Self.debugService
    #else
        var service = Self.releaseService
    #endif
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: Self.account,
        ]
    }
    public init() {}
    public func read() throws -> Data? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AuthFailure.keychain(status) }
        return result as? Data
    }
    public func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw AuthFailure.keychain(added) }
        } else if status != errSecSuccess {
            throw AuthFailure.keychain(status)
        }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthFailure.keychain(status) }
    }
}

/// Never follows redirects with manually attached cookies. No shared browser cookie jar.
final class NoAuthRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public actor WebSessionAuthorizer {
    static let worldURL = URL(string: "https://chat.google.com/mole/world")!
    static var bootstrapURL: URL {
        var url = URLComponents(url: worldURL, resolvingAgainstBaseURL: false)!
        // Protocol inputs observed in the reference's Gmail Chat-shell bootstrap.
        // The historical shell descriptor is intentional; compatibility must be proved live.
        let descriptor =
            #"["h_hs",null,null,[1,0],null,null,"gmail.pinto-server_20230730.06_p0",1,null,[15,38,36,35,26,30,41,18,24,11,21,14,6],null,null,"3Mu86PSulM4.en..es5",0,null,null,[0]]"#
        url.queryItems = [
            "origin": "https://mail.google.com", "shell": "9", "hl": "en", "wfi": "gtn-roster-iframe-id",
            "hs": descriptor,
        ]
        .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    private let vault: any SessionVault
    private let session: URLSession
    private var xsrf: String?
    /// The bootstrap page load in flight: requests that find no token wait for it instead of each loading the page.
    private var xsrfFetch: Task<(String, HTTPURLResponse), any Error>?
    private var generation = 0
    private var punctualBlock: String?  // the realtime registration from the last bootstrap page
    public init(vault: any SessionVault = KeychainSessionVault(), session: URLSession? = nil) {
        self.vault = vault
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config, delegate: NoAuthRedirects(), delegateQueue: nil)
        }
    }
    static func extractXSRF(_ page: String) -> String? { pageValue("SMqcke", in: page) }
    /// A string from a Google page's global data (`"<key>":"<value>"`), one line, not empty.
    static func pageValue(_ key: String, in page: String) -> String? {
        // Accept JSON escapes and optional whitespace, without printing the HTML.
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"" + #"\s*:\s*("(?:[^"\\]|\\.)*")"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
            let range = Range(match.range(at: 1), in: page),
            let array = try? JSONSerialization.jsonObject(with: Data("[\(page[range])]".utf8)) as? [String],
            let token = array.first, !token.isEmpty, !token.contains(where: { $0 == "\r" || $0 == "\n" })
        else { return nil }
        return token
    }
    /// How a host's requests are signed, as Google Chat's web signs them: Chat with its XSRF token, Google's API services
    /// (`GoogleHost`) with the SAPISID hash, Google Contacts with cookies alone (its token goes in the body). Nil: never
    /// sent a signed request. Only Chat's answers can end the session.
    enum Signing { case chat, sapisid, cookies }
    static func signing(_ host: String?) -> Signing? {
        switch host {
        case "chat.google.com": .chat
        case GoogleContacts.host: .cookies
        case let host? where GoogleHost(rawValue: host) != nil: .sapisid
        default: nil
        }
    }
    static func validateDestination(_ url: URL?) throws {
        guard let url, url.scheme == "https", Self.signing(url.host) != nil,
            url.port == nil || url.port == 443, url.user == nil, url.password == nil
        else { throw AuthFailure.invalidDestination }
    }
    public func signIn(cookies: [SessionCookie], userAgent: String) async throws {
        generation += 1
        let current = generation
        let usable = cookies.filter { $0.applies(to: Self.worldURL) }
        guard !usable.isEmpty else { throw AuthFailure.invalidSession }
        guard !userAgent.isEmpty, userAgent.count <= 1024, !userAgent.contains(where: { $0 == "\r" || $0 == "\n" })
        else { throw AuthFailure.invalidSession }
        var credentials = WebCredentials(cookies: cookies, userAgent: userAgent)
        let (token, bootstrap) = try await fetchXSRF(credentials)
        guard current == generation else { throw CancellationError() }
        try Task.checkCancellation()
        credentials.cookies = SessionCookie.merging(credentials.cookies, from: bootstrap)
        try vault.write(JSONEncoder().encode(credentials))
        xsrf = token
    }
    public func signOut() throws {
        generation += 1
        xsrf = nil
        xsrfFetch = nil
        try vault.delete()
    }
    private func storedCredentials() throws -> WebCredentials {
        guard let data = try vault.read() else { throw AuthFailure.signInRequired }
        if let credentials = try? JSONDecoder().decode(WebCredentials.self, from: data), !credentials.cookies.isEmpty {
            return credentials
        }
        try signOut()
        throw AuthFailure.signInRequired
    }
    /// Saves the response's cookie updates into the stored session, writing only when something changed.
    /// Skipped once the session was signed out or replaced, so a late response cannot bring it back.
    private func saveCookies(from response: HTTPURLResponse, generation current: Int) {
        guard current == generation, response.value(forHTTPHeaderField: "Set-Cookie") != nil,
            var credentials = try? storedCredentials()
        else { return }
        let merged = SessionCookie.merging(credentials.cookies, from: response)
        guard merged != credentials.cookies else { return }
        credentials.cookies = merged
        try? vault.write(JSONEncoder().encode(credentials))
    }
    private func fetchXSRF(_ credentials: WebCredentials) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: Self.bootstrapURL)
        let header = SessionCookie.header(credentials.cookies, for: Self.bootstrapURL)
        guard !header.isEmpty else { throw AuthFailure.signInRequired }
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://mail.google.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AuthFailure.unexpectedResponse }
        if (300..<400).contains(response.statusCode) {
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            let host = URL(string: location, relativeTo: Self.bootstrapURL)?.host
            // Fixed categories only: never log redirect URLs or query parameters.
            let category =
                host == "accounts.google.com"
                ? AuthFailure.signInCategory
                : host == "chat.google.com" ? "another Google Chat page" : "an unexpected destination"
            throw AuthFailure.bootstrapRedirect(category)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw Self.isSignInPage(response, body: String(decoding: data, as: UTF8.self))
                ? AuthFailure.signInRequired : AuthFailure.bootstrapRejected(response.statusCode)
        }
        guard response.statusCode == 200 else { throw AuthFailure.http(response.statusCode) }
        let page = String(decoding: data, as: UTF8.self)
        guard let token = Self.extractXSRF(page) else { throw AuthFailure.bootstrapTokenMissing }
        punctualBlock = PunctualWire.registrationBlock(in: page)
        return (token, response)
    }
    /// The realtime (Punctual) registration from the bootstrap page, as JSON; `fresh` loads the page again.
    func punctualRegistration(fresh: Bool = false) async throws -> String? {
        guard fresh || punctualBlock == nil else { return punctualBlock }
        let current = generation
        do {
            let (token, bootstrap) = try await fetchXSRF(try storedCredentials())
            guard current == generation else { throw CancellationError() }
            xsrf = token
            saveCookies(from: bootstrap, generation: current)
        } catch let failure as AuthFailure where failure.endsSession && current == generation {
            try signOut()
            throw failure
        }
        return punctualBlock
    }
    /// `Authorization` for Google's cookie-authenticated APIs: `SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>`.
    static func sapisidHash(
        _ cookies: [SessionCookie], at date: Date = .now, origin: String = "https://chat.google.com"
    ) -> String? {
        guard
            let sapisid = (cookies.first { $0.name == "SAPISID" } ?? cookies.first { $0.name == "__Secure-3PAPISID" })?
                .value,
            !sapisid.isEmpty
        else { return nil }
        let seconds = Int(date.timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(seconds) \(sapisid) \(origin)".utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "SAPISIDHASH \(seconds)_\(digest)"
    }
    /// Auth failures get one fresh bootstrap and retry. A second failure clears the session only when Google answers
    /// with its sign-in page; otherwise the fresh bootstrap proved the session alive and the status is thrown as `.http`.
    func data(for original: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await perform(
            original, { [session] in try await session.data(for: $0) },
            text: { String(decoding: $0, as: UTF8.self) })
    }
    /// Streaming variant for the realtime channel: same checks, credentials and retry as `data(for:)`; returns once headers arrive.
    func bytes(for original: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await perform(
            original, { [session] in try await session.bytes(for: $0) },
            text: { bytes in
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= 1 << 20 { break }
                    }
                } catch {}
                return String(decoding: data, as: UTF8.self)
            })
    }
    /// Why Google refused a request, for the log: the readable runs of its error body (its status names the problem),
    /// without addresses or cookie values, at most 300 characters.
    nonisolated static func reason(_ body: Data) -> String {
        let runs = String(decoding: body, as: UTF8.self).split {
            !$0.isASCII || $0.isNewline || ($0.asciiValue ?? 0) < 32
        }
        let text = runs.filter { $0.count >= 6 }.joined(separator: " ")
        return String(Redaction.redact(text).prefix(300))
    }
    /// Google's sign-in page served in place of the requested resource: a redirect to accounts.google.com,
    /// or the page itself, which names the `AccountsSignInUi` app in its global data.
    static func isSignInPage(_ response: HTTPURLResponse, body: String) -> Bool {
        if let location = response.value(forHTTPHeaderField: "Location"),
            URL(string: location, relativeTo: response.url)?.host?.lowercased() == "accounts.google.com"
        {
            return true
        }
        return body.range(of: #"qwAQke\\?"\s*:\s*\\?"AccountsSignInUi"#, options: .regularExpression) != nil
    }
    private func perform<Body: Sendable>(
        _ original: URLRequest,
        _ transport: @Sendable (URLRequest) async throws -> (Body, URLResponse),
        text: @Sendable (Body) async -> String
    ) async throws -> (Body, HTTPURLResponse) {
        try Self.validateDestination(original.url)
        let current = generation
        do {
            for attempt in 0...1 {
                try await loadXSRFIfNeeded(generation: current)
                let sentToken = xsrf
                guard current == generation else { throw CancellationError() }
                try Task.checkCancellation()
                // Read per attempt so a retry carries cookies the failed reply or the bootstrap just updated.
                let credentials = try storedCredentials()
                let signing = Self.signing(original.url!.host)
                let (body, response) = try await transport(
                    try signed(original, credentials: credentials, signing: signing))
                guard current == generation else { throw CancellationError() }
                guard let response = response as? HTTPURLResponse else { throw AuthFailure.unexpectedResponse }
                saveCookies(from: response, generation: current)
                // Another service's refusal or redirect is its own: Chat's token and session stay, and its client retries.
                if signing != .chat,
                    response.statusCode == 401 || response.statusCode == 403
                        || (300..<400).contains(response.statusCode)
                {
                    authLog.error(
                        "\(original.url?.host ?? "?", privacy: .public) refused (\(response.statusCode, privacy: .public))"
                    )
                    throw AuthFailure.http(response.statusCode)
                }
                if response.statusCode == 401 || response.statusCode == 403 {
                    if xsrf == sentToken { xsrf = nil }  // not one another request has just refreshed
                    if attempt == 0 { continue }
                    let page = await text(body)
                    if Self.isSignInPage(response, body: page) { throw AuthFailure.signInRequired }
                    authLog.error(
                        "\(original.url?.path ?? "?", privacy: .public) refused (\(response.statusCode, privacy: .public)): \(Self.reason(Data(page.utf8)), privacy: .public)"
                    )
                    throw AuthFailure.http(response.statusCode)
                }
                if (300..<400).contains(response.statusCode) {  // a proxy or captive-portal redirect is not a sign-out
                    throw Self.isSignInPage(response, body: "")
                        ? AuthFailure.signInRequired : AuthFailure.http(response.statusCode)
                }
                guard response.statusCode == 200 else {
                    let reason = Self.reason(Data(await text(body).utf8))
                    authLog.error(
                        "\(original.url?.path ?? "?", privacy: .public) refused (\(response.statusCode, privacy: .public)): \(reason, privacy: .public)"
                    )
                    throw AuthFailure.http(response.statusCode)
                }
                return (body, response)
            }
            throw AuthFailure.signInRequired
        } catch let failure as AuthFailure {
            try endSessionIfNeeded(failure, at: original.url, generation: current)
            throw failure
        }
    }
    /// Waits for the bootstrap's XSRF token when there is none. Requests that find none share one page load.
    private func loadXSRFIfNeeded(generation current: Int) async throws {
        guard xsrf == nil else { return }
        let fetch = xsrfFetch ?? Task { try await fetchXSRF(try storedCredentials()) }
        xsrfFetch = fetch
        let result: (String, HTTPURLResponse)
        do { result = try await fetch.value } catch {
            if xsrfFetch == fetch { xsrfFetch = nil }
            throw error
        }
        if xsrfFetch == fetch { xsrfFetch = nil }
        guard current == generation else { throw CancellationError() }
        xsrf = result.0
        saveCookies(from: result.1, generation: current)
    }
    /// `original` with the session's cookies and the headers its host is signed with.
    private func signed(_ original: URLRequest, credentials: WebCredentials, signing: Signing?) throws -> URLRequest {
        var request = original
        let header = SessionCookie.header(credentials.cookies, for: original.url!)
        guard !header.isEmpty else { throw AuthFailure.signInRequired }
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        if signing == .chat { request.setValue(xsrf, forHTTPHeaderField: "X-Framework-XSRF-Token") }
        request.setValue("https://chat.google.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chat.google.com/", forHTTPHeaderField: "Referer")
        // The realtime channel also wants the SAPISID hash, as Google Chat sends it there.
        if signing == .sapisid || original.url!.path.hasPrefix("/punctual/"),
            let hash = Self.sapisidHash(credentials.cookies)
        {
            request.setValue(hash, forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
        return request
    }
    /// Media over the stored session. get_attachment_url answers with a redirect to a content host, which `data(for:)`
    /// treats as a lost session, so media follows redirects here: HTTPS only, at most five hops, cookies re-scoped per hop
    /// by `SessionCookie` (Google hosts only), no XSRF. `media` must not follow redirects itself (`NoAuthRedirects`).
    func mediaData(from start: URL, session media: URLSession) async throws -> Data {
        guard let stored = try vault.read(),
            let credentials = try? JSONDecoder().decode(WebCredentials.self, from: stored)
        else {
            throw AuthFailure.signInRequired
        }
        var url = start
        for _ in 0..<5 {
            guard url.scheme == "https", url.user == nil, url.password == nil else {
                throw AuthFailure.invalidDestination
            }
            if url.host() == "accounts.google.com" { throw AuthFailure.signInRequired }
            var request = URLRequest(url: url)
            let cookies = SessionCookie.header(credentials.cookies, for: url)
            if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
            request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await media.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AuthFailure.unexpectedResponse }
            switch response.statusCode {
            case 200: return data
            case 300..<400:
                guard
                    let next = response.value(forHTTPHeaderField: "Location").flatMap({
                        URL(string: $0, relativeTo: url)?.absoluteURL
                    })
                else {
                    throw AuthFailure.unexpectedResponse
                }
                url = next
            default: throw AuthFailure.http(response.statusCode)
            }
        }
        throw AuthFailure.unexpectedResponse
    }
    /// Signs out when `failure` ends the session and the session is still the one the request was sent with.
    private func endSessionIfNeeded(_ failure: AuthFailure, at url: URL?, generation current: Int) throws {
        guard failure.endsSession, current == generation else { return }
        // Only the request that ended a stored session: path only, no query string.
        if (try? vault.read()) != nil {
            authLog.notice(
                "Google ended the session at \(url?.path ?? "?", privacy: .public): \(String(describing: failure), privacy: .public)"
            )
        }
        try signOut()
    }
}
