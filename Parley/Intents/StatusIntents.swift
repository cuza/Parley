import AppIntents

/// How long Do Not Disturb lasts: the status menu's choices.
enum DoNotDisturbDuration: String, AppEnum {
    case halfHour, hour, twoHours, fourHours, eightHours, day
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Duration"
    static let caseDisplayRepresentations: [DoNotDisturbDuration: DisplayRepresentation] = [
        .halfHour: "30 minutes", .hour: "1 hour", .twoHours: "2 hours", .fourHours: "4 hours", .eightHours: "8 hours",
        .day: "24 hours",
    ]
    var seconds: TimeInterval {
        switch self {
        case .halfHour: 1800
        case .hour: 3600
        case .twoHours: 7200
        case .fourHours: 14_400
        case .eightHours: 28_800
        case .day: 86_400
        }
    }
}

/// Google Chat's Do Not Disturb, as the status menu turns it on: for everyone who sees my status, on every device.
struct SetDoNotDisturbIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Do Not Disturb"
    static let description = IntentDescription(
        "Turns on Google Chat's Do Not Disturb for a while. Others see it, and Google Chat holds notifications on every device."
    )
    static var parameterSummary: some ParameterSummary { Summary("Turn on Do Not Disturb for \(\.$duration)") }
    @Parameter(title: "Duration", default: .hour) var duration: DoNotDisturbDuration
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.changeStatus { await $0.setDoNotDisturb(for: duration.seconds) }
        return .result()
    }
}

struct SetAwayIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Away"
    static let description = IntentDescription(
        "Shows you as away in Google Chat until you set your status back to automatic.")
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.changeStatus { await $0.setAway(true) }
        return .result()
    }
}

/// Back to automatic: ends Away and Do Not Disturb, as the status menu's Automatic does.
struct SetAutomaticStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Status to Automatic"
    static let description = IntentDescription(
        "Ends Away and Do Not Disturb, so Google Chat shows you as active when you are.")
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.changeStatus { await $0.setAway(false) }
        return .result()
    }
}

struct ClearCustomStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Custom Status"
    static let description = IntentDescription("Removes your Google Chat status message.")
    @Dependency private var store: ChatStore
    @MainActor func perform() async throws -> some IntentResult {
        try await store.changeStatus { await $0.setCustomStatus(nil) }
        return .result()
    }
}
