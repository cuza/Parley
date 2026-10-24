import Foundation

@testable import Parley
@testable import ParleyData
@testable import ParleyDomain

extension SessionCookie {
    /// The session cookie a stubbed session stores; its requests carry `Cookie: SID=test-session`.
    static let testSID = SessionCookie(
        name: "SID", value: "test-session", domain: ".google.com", path: "/", secure: true, expires: -1)
}

/// A signed-in session for network-stubbed tests: the session stored as the Keychain keeps it, and requests answered by
/// a stub exchange, the bootstrap page with its XSRF token first.
extension NetworkSuite {
    /// The bootstrap page's answer: the XSRF token.
    static var xsrfReply: StubExchange.Reply { .init(data: Data(#"{"SMqcke":"test-xsrf"}"#.utf8)) }
    /// Google's sign-in page in place of an answer: the session has ended.
    static var signInPage: StubExchange.Reply {
        .init(
            status: 401,
            data: Data(#"<script>window.WIZ_global_data = {"qwAQke":"AccountsSignInUi","SNlM0e":""};</script>"#.utf8))
    }
    /// A vault holding a session with `cookies` and `userAgent`.
    static func storedSession(_ cookies: [SessionCookie] = [.testSID], userAgent: String = "TestAgent/1") throws
        -> MemoryVault
    {
        let vault = MemoryVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: userAgent)))
        return vault
    }
    /// An authorizer for the session in `vault` (by default a stored SID), its requests answered by `bootstrap` (by
    /// default the XSRF token) and then `replies`, in turn.
    static func signedIn(
        _ replies: [StubExchange.Reply], bootstrap: StubExchange.Reply? = nil,
        vault: MemoryVault? = nil
    ) throws -> (WebSessionAuthorizer, StubExchange) {
        let exchange = StubExchange([bootstrap ?? xsrfReply] + replies)
        return (
            WebSessionAuthorizer(vault: try vault ?? storedSession(), session: AuthStubProtocol.session(exchange)),
            exchange
        )
    }
}
