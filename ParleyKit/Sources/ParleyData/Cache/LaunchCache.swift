import Foundation
import ParleyDomain

/// The launch cache as a JSON file in Application Support.
public struct LaunchCache: LaunchCaching {
    let url: URL
    #if DEBUG  // its own file, as with the Keychain: a debug build signed into another account doesn't swap the installed app's
        public static let dynamite = LaunchCache(
            url: URL.applicationSupportDirectory.appending(path: "Parley/cache-debug.json"))
    #else
        public static let dynamite = LaunchCache(
            url: URL.applicationSupportDirectory.appending(path: "Parley/cache.json"))
    #endif
    /// A file this build can't read at all is moved aside (`.unreadable`) rather than overwritten by the next save.
    public func load() -> LaunchSnapshot {
        guard let data = try? Data(contentsOf: url) else { return LaunchSnapshot() }
        guard let value = try? JSONDecoder().decode(LaunchSnapshot.self, from: data) else {
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return LaunchSnapshot()
        }
        return value
    }
    public func save(_ snapshot: LaunchSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
