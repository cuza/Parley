import Foundation
import Testing

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

extension NetworkTests { @Suite struct AuthTests: NetworkSuite {} }

extension NetworkTests.AuthTests {
    private var cookie: SessionCookie {
        SessionCookie(name: "SID", value: "test-session", domain: ".google.com", path: "/", secure: true, expires: -1)
    }
    private var bootstrap: StubExchange.Reply { .init(data: Data(#"{"SMqcke":"test-xsrf"}"#.utf8)) }
    private var rpc: URLRequest { URLRequest(url: URL(string: "https://chat.google.com/api/get_self_user_status")!) }

    @Test func cookieScopeAndExpiry() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(cookie.applies(to: WebSessionAuthorizer.worldURL, now: now))
        #expect(!cookie.applies(to: URL(string: "https://google.com.evil.test/")!, now: now))
        #expect(!cookie.applies(to: URL(string: "http://chat.google.com/")!, now: now))
        var expired = cookie
        expired.expires = 99
        #expect(!expired.applies(to: WebSessionAuthorizer.worldURL, now: now))
        var hostOnly = cookie
        hostOnly.domain = "google.com"
        #expect(!hostOnly.applies(to: WebSessionAuthorizer.worldURL, now: now))
        var malicious = cookie
        malicious.domain = ".evilgoogle.com"
        #expect(!malicious.applies(to: WebSessionAuthorizer.worldURL, now: now))
    }
    @Test func cookiePathBoundaryAndDuplicateNames() {
        var narrow = cookie
        narrow.path = "/api"
        narrow.value = "narrow"
        #expect(!narrow.applies(to: URL(string: "https://chat.google.com/apix")!))
        #expect(narrow.applies(to: rpc.url!))
        #expect(SessionCookie.header([cookie, narrow], for: rpc.url!) == "SID=narrow; SID=test-session")
    }
    @Test func rejectsCookieHeaderInjection() {
        var invalid = cookie
        invalid.value = "safe\r\nAuthorization: other"
        #expect(!invalid.applies(to: rpc.url!))
        invalid = cookie
        invalid.name = "SID; attacker"
        #expect(!invalid.applies(to: rpc.url!))
    }
    @Test func xsrfHandlesWhitespaceAndJSONEscapes() {
        #expect(WebSessionAuthorizer.extractXSRF(#"{"SMqcke" : "a\u003db\/c"}"#) == "a=b/c")
        #expect(WebSessionAuthorizer.extractXSRF("<html></html>") == nil)
        #expect(WebSessionAuthorizer.extractXSRF(#"{"SMqcke":""}"#) == nil)
        #expect(WebSessionAuthorizer.extractXSRF(#"{"SMqcke":"a\nb"}"#) == nil)
    }
    @Test func credentialsNeverGoToAnotherHost() {
        for address in [
            "http://chat.google.com/api/x", "https://chat.google.com.evil.test/api/x", "https://accounts.google.com/",
            "https://chat.google.com:444/api/x", "https://user@chat.google.com/api/x",
        ] {
            #expect(throws: AuthFailure.invalidDestination) {
                try WebSessionAuthorizer.validateDestination(URL(string: address))
            }
        }
        #expect(throws: Never.self) { try WebSessionAuthorizer.validateDestination(rpc.url) }
    }
    /// The stored session as installed copies hold it today: every later build must read it, or an update signs everyone
    /// out. Change the format only with a migration, and keep this sample decoding. (Fake values.)
    @Test func theStoredSessionFormatStillDecodes() throws {
        let stored =
            #"{"cookies":[{"name":"SID","value":"fake","domain":".google.com","path":"\/","secure":true,"expires":1893456000}],"userAgent":"Mozilla\/5.0 Safari"}"#
        let credentials = try JSONDecoder().decode(WebCredentials.self, from: Data(stored.utf8))
        #expect(
            credentials.cookies == [
                SessionCookie(
                    name: "SID", value: "fake", domain: ".google.com", path: "/", secure: true, expires: 1_893_456_000)
            ])
        #expect(credentials.userAgent == "Mozilla/5.0 Safari")
        #expect(KeychainSessionVault.releaseService == "dev.cuza.Parley")
        #expect(KeychainSessionVault.debugService == "dev.cuza.Parley.debug")
        #expect(KeychainSessionVault.account == "dynamite.web-session")
    }
    /// Debug builds (and so the test host) never share the installed app's session entry or sign-in data.
    @MainActor @Test func debugBuildsKeepTheirOwnSession() {
        #expect(KeychainSessionVault().service == "dev.cuza.Parley.debug")
        #expect(WebViewSignIn.storeID.uuidString != "4F7A2C1E-9B3D-4E8A-A6C5-2D1F0B9E7C34")
    }
    @Test func validatedSessionIsSavedAndRestored() async throws {
        let vault = MemoryVault()
        let exchange = StubExchange([bootstrap, bootstrap, .init(data: Data([1, 2]))])
        let session = AuthStubProtocol.session(exchange)
        let auth = WebSessionAuthorizer(vault: vault, session: session)
        try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        #expect(vault.read() != nil)
        #expect(try JSONDecoder().decode(WebCredentials.self, from: vault.read()!).cookies == [cookie])
        let restored = WebSessionAuthorizer(vault: vault, session: session)
        let (bytes, _) = try await restored.data(for: rpc)
        #expect(bytes == Data([1, 2]))
        #expect(exchange.requests.count == 3)
        #expect(exchange.requests.last?.value(forHTTPHeaderField: "Cookie") == "SID=test-session")
        #expect(exchange.requests.last?.value(forHTTPHeaderField: "X-Framework-XSRF-Token") == "test-xsrf")
        try await restored.signOut()
        #expect(vault.read() == nil)
    }
    @Test func failedBootstrapDoesNotPersistCandidateCookies() async {
        let vault = MemoryVault()
        let exchange = StubExchange([.init(status: 302, headers: ["Location": "https://accounts.google.com/"])])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.bootstrapRedirect("Google sign-in")) {
            try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        }
        #expect(vault.read() == nil)
    }
    @Test func expiredRPCRefreshesBootstrapOnce() async throws {
        let vault = MemoryVault()
        let exchange = StubExchange([
            bootstrap, .init(status: 403), .init(data: Data(#"{"SMqcke":"new-xsrf"}"#.utf8)), .init(data: Data([7])),
        ])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        let (bytes, _) = try await auth.data(for: rpc)
        #expect(bytes == Data([7]))
        #expect(exchange.requests.count == 4)
        #expect(exchange.requests.last?.value(forHTTPHeaderField: "X-Framework-XSRF-Token") == "new-xsrf")
    }
    @Test func repeatedUnauthorizedKeepsLiveSession() async throws {
        let vault = MemoryVault()
        let exchange = StubExchange([bootstrap, .init(status: 401), bootstrap, .init(status: 403)])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        await #expect(throws: AuthFailure.http(403)) { _ = try await auth.data(for: rpc) }
        #expect(exchange.requests.count == 4)
        #expect(vault.read() != nil)
    }
    /// A 403 on the bootstrap page that isn't Google's sign-in page (a proxy, an access policy, throttling) keeps the stored
    /// session: the realtime channel reloads that page on every reconnect, and one refusal used to force a full sign-in.
    @Test func aRefusedBootstrapKeepsTheSession() async throws {
        let vault = MemoryVault()
        let exchange = StubExchange([bootstrap, .init(status: 403, data: Data("<html>Forbidden</html>".utf8))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        await #expect(throws: AuthFailure.bootstrapRejected(403)) {
            _ = try await auth.punctualRegistration(fresh: true)
        }
        #expect(vault.read() != nil)
    }
    /// Google's sign-in page in place of the bootstrap page does end it.
    @Test func aBootstrapAnsweredWithTheSignInPageEndsTheSession() async throws {
        let vault = MemoryVault()
        let exchange = StubExchange([
            bootstrap, .init(status: 401, data: Data(#"<script>{"qwAQke":"AccountsSignInUi"}</script>"#.utf8)),
        ])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.punctualRegistration(fresh: true) }
        #expect(vault.read() == nil)
    }
    /// Requests that start together without a token share one bootstrap page load, instead of each loading the page.
    @Test func concurrentRequestsShareOneTokenFetch() async throws {
        let vault = MemoryVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [cookie], userAgent: "test-agent")))
        var slowBootstrap = bootstrap
        slowBootstrap.delay = 0.3
        let exchange = StubExchange([
            slowBootstrap, .init(data: Data([1])), .init(data: Data([2])), .init(data: Data([3])),
        ])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        async let first = auth.data(for: rpc)
        async let second = auth.data(for: rpc)
        async let third = auth.data(for: rpc)
        _ = try await (first, second, third)
        #expect(exchange.requests.filter { $0.url?.path == WebSessionAuthorizer.bootstrapURL.path }.count == 1)
    }
    @Test func transientHTTPFailurePreservesSession() async throws {
        let vault = MemoryVault()
        let exchange = StubExchange([bootstrap, .init(status: 503)])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        await #expect(throws: AuthFailure.http(503)) { _ = try await auth.data(for: rpc) }
        #expect(vault.read() != nil)
    }
    @Test func aCookieOnlyEntryFromTheFirstBuildsSignsOut() async throws {  // that format is gone; signing in again replaces it
        let vault = MemoryVault()
        try vault.write(JSONEncoder().encode([cookie]))
        let exchange = StubExchange([])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.data(for: rpc) }
        #expect(exchange.requests.isEmpty && vault.read() == nil)
    }
    @Test func missingSessionDoesNotMakeRequests() async {
        let exchange = StubExchange([])
        let auth = WebSessionAuthorizer(vault: MemoryVault(), session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.data(for: rpc) }
        #expect(exchange.requests.isEmpty)
    }
    @Test func readProbePaginatesAndCountsUniqueConversations() async throws {
        let identity = ProbeWire.message(1, ProbeWire.message(1, ProbeWire.string(1, "user")))
        let room = ProbeWire.message(1, ProbeWire.message(1, ProbeWire.string(1, "room")))
        let dm = ProbeWire.message(1, ProbeWire.message(3, ProbeWire.string(1, "dm")))
        let first = ProbeWire.message(
            1, ProbeWire.message(2, room) + ProbeWire.integer(5, 1) + ProbeWire.string(6, "next"))
        let last = ProbeWire.message(4, room) + ProbeWire.message(4, dm)
        let headers = ["Content-Type": "application/x-protobuf"]
        let exchange = StubExchange([
            bootstrap, .init(headers: headers, data: identity), .init(headers: headers, data: first),
            .init(headers: headers, data: last),
        ])
        let auth = WebSessionAuthorizer(vault: MemoryVault(), session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
        let result = try await DynamiteReadProbe(authorizer: auth).run()
        #expect(result.conversationCount == 2)
        #expect(exchange.requests.count == 4)
        #expect(exchange.requests.last?.url?.query == "rt=b")
    }
    @Test func missingBootstrapTokenPreservesSessionForDiagnosis() async throws {
        let vault = MemoryVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [cookie], userAgent: "test-agent")))
        let exchange = StubExchange([.init(status: 200, data: Data("<html>Sign in</html>".utf8))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.bootstrapTokenMissing) { _ = try await auth.data(for: rpc) }
        #expect(vault.read() != nil)
    }
    @Test func bootstrapIncludesShellInputsAndCapturedUserAgent() async throws {
        let exchange = StubExchange([bootstrap])
        let vault = MemoryVault()
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [cookie], userAgent: "Chrome-test-user-agent")
        let request = try #require(exchange.requests.first)
        let params = Dictionary(
            uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map {
                ($0.name, $0.value!)
            })
        #expect(params["shell"] == "9")
        #expect(params["origin"] == "https://mail.google.com")
        #expect(params["wfi"] == "gtn-roster-iframe-id")
        #expect(params["hs"]?.contains("h_hs") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Chrome-test-user-agent")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://mail.google.com/")
        #expect(
            try JSONDecoder().decode(WebCredentials.self, from: vault.read()!).userAgent == "Chrome-test-user-agent")
    }
    @Test func bootstrapDiagnosticsDoNotExposeRedirectURL() async {
        let exchange = StubExchange([
            .init(status: 302, headers: ["Location": "https://accounts.google.com/?secret=private"])
        ])
        let auth = WebSessionAuthorizer(vault: MemoryVault(), session: AuthStubProtocol.session(exchange))
        do {
            try await auth.signIn(cookies: [cookie], userAgent: "test-agent")
            Issue.record("Expected redirect failure")
        } catch {
            #expect(error.localizedDescription.contains("Google sign-in"))
            #expect(!error.localizedDescription.contains("private"))
        }
    }
    @Test func corruptVaultIsCleared() async {
        let vault = MemoryVault()
        vault.write(Data("garbage".utf8))
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(StubExchange([])))
        await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.data(for: rpc) }
        #expect(vault.read() == nil)
    }
}
