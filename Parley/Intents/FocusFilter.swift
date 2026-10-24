import AppIntents
import Foundation
import ParleyDomain

/// A Focus's Parley filter (System Settings ▸ Focus ▸ a Focus ▸ Focus Filters): Google Chat's Do Not Disturb or a
/// status while the Focus is on. The system runs it as the Focus turns on, and again with nothing set as it turns off.
struct ParleyFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Google Chat Status"
    static let description = IntentDescription(
        "Turns on Do Not Disturb or sets a status in Google Chat while this Focus is on, and takes it back afterwards.")
    @Parameter(title: "Do Not Disturb", default: false) var doNotDisturb: Bool
    @Parameter(title: "Status") var status: String?
    @Parameter(title: "Status Emoji") var emoji: String?
    @Dependency private var store: ChatStore

    var displayRepresentation: DisplayRepresentation {
        let parts = [doNotDisturb ? "Do Not Disturb" : nil, status.map { "“\($0)”" }].compactMap { $0 }
        return DisplayRepresentation(title: parts.isEmpty ? "No change" : "\(parts.joined(separator: ", "))")
    }

    @MainActor func perform() async throws -> some IntentResult {
        try await FocusStatus(doNotDisturb: doNotDisturb, status: status, emoji: emoji ?? "").apply(to: store)
        return .result()
    }
}

/// What a Focus filter sets in Google Chat. The last one applied is kept on this Mac, so turning a Focus off takes back
/// only what its filter set.
// ponytail: a status changed by hand during the Focus is still cleared as it ends; compare with the current status
// if that bites.
struct FocusStatus: Codable, Equatable {
    var doNotDisturb = false
    var status: String?
    var emoji = ""

    init(doNotDisturb: Bool = false, status: String? = nil, emoji: String = "") {
        self.doNotDisturb = doNotDisturb
        let text = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.status = text.isEmpty ? nil : text
        self.emoji = self.status == nil ? "" : emoji
    }

    enum Change: Equatable {
        case doNotDisturb, endDoNotDisturb
        case status(String, emoji: String)
        case clearStatus
    }
    /// From what the last run set to what this one wants.
    static func changes(from applied: FocusStatus, to wanted: FocusStatus) -> [Change] {
        var changes: [Change] = []
        if wanted.doNotDisturb != applied.doNotDisturb {
            changes.append(wanted.doNotDisturb ? .doNotDisturb : .endDoNotDisturb)
        }
        if let text = wanted.status {
            if wanted.status != applied.status || wanted.emoji != applied.emoji {
                changes.append(.status(text, emoji: wanted.emoji))
            }
        } else if applied.status != nil {
            changes.append(.clearStatus)
        }
        return changes
    }

    /// Google Chat's longest Do Not Disturb. A Focus that lasts longer outlives it.
    static let doNotDisturbLength: TimeInterval = 86_400
    static let key = "focusFilterApplied"
    static func applied(in defaults: UserDefaults = .standard) -> FocusStatus {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FocusStatus.self, from: $0) } ?? FocusStatus()
    }

    /// Makes Google Chat match this filter, then remembers it. A change Google refuses throws, and what was applied
    /// before stays remembered.
    @MainActor func apply(to store: ChatStore, defaults: UserDefaults = .standard) async throws {
        for change in Self.changes(from: Self.applied(in: defaults), to: self) {
            try await store.changeStatus { store in
                switch change {
                case .doNotDisturb: await store.setDoNotDisturb(for: Self.doNotDisturbLength)
                case .endDoNotDisturb: await store.setAway(false)
                case .status(let text, let emoji): await store.setCustomStatus(CustomStatus(text: text, emoji: emoji))
                case .clearStatus: await store.setCustomStatus(nil)
                }
            }
        }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}
