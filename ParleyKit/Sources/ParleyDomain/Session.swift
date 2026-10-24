import Foundation

/// A Google cookie of the saved session, as the Keychain keeps it.
public struct SessionCookie: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var secure: Bool
    public var expires: Double
    public init(name: String, value: String, domain: String, path: String, secure: Bool, expires: Double) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.expires = expires
    }
}

/// The saved session: its cookies and the browser it was signed in with.
public struct WebCredentials: Codable, Sendable {
    public var cookies: [SessionCookie]
    public var userAgent: String
    public init(cookies: [SessionCookie], userAgent: String) {
        self.cookies = cookies
        self.userAgent = userAgent
    }
}

/// Where the saved session is kept: the Keychain in the app, a fake in tests.
public protocol SessionVault: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// The in-app sign-in window as the flow drives it; tests replace it.
@MainActor public protocol SignInBrowser: AnyObject {
    func start() async throws
    /// Throws `AuthFailure.chatNotOpen` until a Google Chat page is open.
    func captureSession() async throws -> WebCredentials
    func close()
    /// Deletes everything the sign-in window stored, so the next sign-in starts fresh.
    func forget() async
}
extension SignInBrowser {
    func forget() async {}
}

/// What a read check against Google Chat found.
public struct ReadCheckResult: Sendable {
    public var conversationCount: Int
    public init(conversationCount: Int) {
        self.conversationCount = conversationCount
    }
}
