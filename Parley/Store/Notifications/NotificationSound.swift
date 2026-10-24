import AppKit
import UserNotifications

/// The sound a notification plays: macOS's default (played by macOS, its Focus rules and all), none, or a sound installed
/// on the Mac (by file name, from its Sounds folders). macOS plays only its default for an app and swaps any other sound
/// for it, so a named sound's banner goes silent and Parley plays the sound itself, as Slack plays its own.
enum NotificationSound: Hashable, Sendable {
    case standard, none
    case named(String)
    static let key = "messageSound"
    /// The Mac's Sounds folders, as System Settings ▸ Sound lists them: the user's, the Mac's, and macOS's.
    static let folders = [URL.libraryDirectory, URL(filePath: "/Library"), URL(filePath: "/System/Library")].map {
        $0.appending(path: "Sounds")
    }
    var stored: String {
        switch self {
        case .standard: "default"
        case .none: "none"
        case .named(let file): file
        }
    }
    /// A stored choice; Parley's own sounds before (Duet, Drop, Rise) are gone, so they are the default.
    init(stored: String?) {
        switch stored {
        case "none": self = .none
        case let file? where file.contains("."): self = .named(file)
        default: self = .standard
        }
    }
    var name: String {
        switch self {
        case .standard: "Default"
        case .none: "None"
        case .named(let file): (file as NSString).deletingPathExtension
        }
    }
    static var current: NotificationSound { NotificationSound(stored: UserDefaults.standard.string(forKey: key)) }
    /// Default and None, then each sound the folders hold (the formats a notification can play), by name, once each.
    static func available(in folders: [URL] = folders) -> [NotificationSound] {
        let files = folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
            .filter { ["aiff", "aif", "caf", "wav"].contains(($0 as NSString).pathExtension.lowercased()) }
        var seen = Set<String>()
        let named = files.filter { seen.insert(($0 as NSString).deletingPathExtension).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [.standard, .none] + named.map(NotificationSound.named)
    }
    var notificationSound: UNNotificationSound? { self == .standard ? .default : nil }
    var playedByParley: Bool { if case .named = self { true } else { false } }
    /// The sound to hear it in Settings, as System Settings plays an alert sound; none for the default.
    @MainActor var preview: NSSound? {
        guard case .named(let file) = self else { return nil }
        return Self.folders.lazy.map { $0.appending(path: file) }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        .flatMap { NSSound(contentsOf: $0, byReference: true) }
    }
}

/// Whether Parley plays a named sound for a banner just posted: whenever sounds are allowed for Parley in System
/// Settings, during a Focus too, as Slack plays its own. macOS's default follows macOS's rules alone.
enum NotificationSoundPolicy {
    static func plays(_ sound: NotificationSound, soundsAllowed: Bool) -> Bool { sound.playedByParley && soundsAllowed }
}
