import Foundation
import ParleyDomain

/// Settings ▸ General's "At launch, open": Home, as Google Chat opens, or the conversation open at the last quit, as
/// Mail and Messages reopen.
enum LaunchLanding: String, CaseIterable {
    case home, last
    static let key = "launchLanding"
    static var current: LaunchLanding { UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .home }
    var shortcut: Shortcut? { self == .home ? .home : nil }
}
