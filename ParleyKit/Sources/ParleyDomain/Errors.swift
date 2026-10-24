import Foundation

public enum AuthFailure: Error, LocalizedError, Equatable {
    case signInRequired, browserClosed, chatNotOpen
    case invalidSession, invalidDestination, unexpectedResponse, malformedProto
    case http(Int)
    case keychain(OSStatus)
    case bootstrapRejected(Int)
    case bootstrapRedirect(String)
    case bootstrapTokenMissing
    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to Google Chat again."
        case .browserClosed: "The sign-in window was closed. Start a new sign-in."
        case .chatNotOpen: "Finish signing in until Google Chat opens, then try again."
        case .invalidSession: "The sign-in has no usable Google Chat credentials. Finish signing in and try again."
        case .invalidDestination: "Refused to send credentials outside Google Chat."
        case .unexpectedResponse: "Google returned an unexpected response format. The auth check has not passed."
        case .malformedProto: "Google’s response did not match the expected protobuf schema."
        case .bootstrapRejected(let status): "Web bootstrap rejected the imported session (HTTP \(status))."
        case .bootstrapRedirect(let destination):
            "Web bootstrap redirected to \(destination). No credentials were forwarded."
        case .bootstrapTokenMissing:
            "Web bootstrap returned HTTP 200 but no XSRF token. The shell request or response format may have changed."
        case .http(let status): "Google Chat returned HTTP \(status)."
        case .keychain(let status): "Keychain operation failed (\(status))."
        }
    }
    public static let signInCategory = "Google sign-in"
    /// Google sent the session to sign in: it is dead. Anything else (a proxy, a portal, an access policy, throttling, a
    /// protocol change) keeps it for diagnosis and a later retry. A bootstrap 401 or 403 that is Google's sign-in page
    /// comes as `signInRequired`.
    public var endsSession: Bool {
        switch self {
        case .signInRequired: true
        case .bootstrapRedirect(let destination): destination == Self.signInCategory
        default: false
        }
    }
}

public enum DynamiteError: Error, LocalizedError, Equatable {
    case notYetSupported(String)
    case badID, joinRefused, leaveRefused, addRefused, removeRefused
    case appRefused(String)  // an app (or the server for it) refused a card's action, saying why (may be empty)
    case malformedReply  // a reply Parley can't read: it didn't decode, or lacks what the request always gets back
    public var errorDescription: String? {
        switch self {
        case .malformedReply: "Google’s response did not match the expected protobuf schema."
        case .joinRefused: "Google Chat didn’t let you join that space."
        case .leaveRefused: "Google Chat didn’t let you leave that conversation."
        case .addRefused: "Google Chat didn’t let you add that person."
        case .removeRefused: "Google Chat didn’t let you remove that person."
        case .notYetSupported(let feature): "\(feature) isn’t available with Google Chat yet."
        case .badID: "That isn’t a Google Chat conversation or message ID."
        case .appRefused(let why): "The app is unable to process your request." + (why.isEmpty ? "" : " " + why)
        }
    }
}
