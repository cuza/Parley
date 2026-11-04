import ParleyDomain

/// Renews the session without a window; tests replace it.
@MainActor public protocol SessionRenewing: AnyObject {
    func renew() async throws -> WebCredentials
}
