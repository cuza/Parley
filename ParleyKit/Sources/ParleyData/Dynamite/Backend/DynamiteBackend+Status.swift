import Foundation
import ParleyDomain
import SwiftProtobuf

extension DynamiteBackend {
    // Own status, as Google Chat's status menu sets it. Each answer is the status as saved.
    public func setDoNotDisturb(for duration: TimeInterval) async throws -> OwnStatus {
        try await setStatus(
            "set_dnd_duration",
            Dynamite_SetDndDurationRequest.with {
                $0.durationUsec = Int64(duration * 1_000_000)
            })
    }
    public func setAway(_ away: Bool) async throws -> OwnStatus {
        try await setStatus(
            "set_presence_shared",
            Dynamite_SetPresenceSharedRequest.with {
                $0.presenceShared = !away
            })
    }
    /// Always with an absolute expiry (the server also takes a duration); clearing is a zero duration and no status.
    public func setCustomStatus(_ status: CustomStatus?) async throws -> OwnStatus {
        try await setStatus(
            "set_custom_status",
            Dynamite_SetCustomStatusRequest.with { request in
                if let status {
                    request.customStatus.statusText = status.text
                    request.customStatus.emoji.unicode = status.emoji
                    if let expires = status.expires {
                        request.expiryTimestampUsec = Int64(expires.timeIntervalSince1970 * 1_000_000)
                    }
                } else {
                    request.durationUsec = 0
                }
            })
    }
    private func setStatus(_ method: String, _ request: some DynamiteRequest) async throws -> OwnStatus {
        let response: Dynamite_SetUserStatusResponse = try await rpc(method, request)
        return DynamiteMapper.ownStatus(response.userStatus)
    }
    /// `get_user_presence`: 1 is active, any other value away; DND wins. Self is never asked for.
    public func fetchPresence(_ ids: [PersonID]) async throws {
        let ids = ids.filter { !$0.rawValue.isEmpty && $0.rawValue != selfID }
        guard !ids.isEmpty else { return }
        let request = Dynamite_GetUserPresenceRequest.with { request in
            request.userIds = ids.map { id in .with { $0.id = id.rawValue } }
        }
        let response: Dynamite_GetUserPresenceResponse = try await rpc("get_user_presence", request)
        for presence in response.userPresences where !presence.userID.id.isEmpty {
            let state: Presence =
                presence.dndState == .dnd || presence.userStatus.dndSettings.dndState == .dnd
                ? .doNotDisturb
                : presence.presence == .active ? .available : .away
            continuation.yield(
                .presenceChanged(
                    PersonID(presence.userID.id), state, status: DynamiteMapper.customStatus(presence.userStatus)))
        }
    }

    /// `get_recurring_dnd` with the time zone, which Google needs.
    public func dndSchedules(timeZone: String) async throws -> DndSchedules {
        let response: Dynamite_GetRecurringDndResponse = try await rpc(
            "get_recurring_dnd",
            Dynamite_GetRecurringDndRequest.with {
                $0.timeZone = timeZone
            })
        return Self.schedules(response.recurringDnd, timeZone: timeZone)
    }
    static func schedules(_ proto: Dynamite_RecurringDnd, timeZone: String) -> DndSchedules {
        DndSchedules(
            periods: proto.schedules.map {
                .init(days: $0.days.map(Int.init), start: Int($0.start), end: Int($0.end), enabled: $0.enabled)
            },
            followsTimeZone: proto.updatesOnTimeZoneChange, timeZone: proto.timeZone.isEmpty ? timeZone : proto.timeZone
        )
    }
    /// `set_recurring_dnd` with the whole set and field 2 at 0, as Google Chat sends it. A period switched on that covers
    /// now turns DND on at once: the reply's status says so.
    public func setDndSchedules(_ schedules: DndSchedules) async throws {
        let request = Dynamite_SetRecurringDndRequest.with { request in
            request.recurringDnd.schedules = schedules.periods.map { period in
                .with {
                    $0.days = period.days.map(Int32.init)
                    $0.start = Int32(period.start)
                    $0.end = Int32(period.end)
                    $0.enabled = period.enabled
                }
            }
            request.recurringDnd.updatesOnTimeZoneChange = schedules.followsTimeZone
            request.recurringDnd.timeZone = schedules.timeZone
            request.field2 = 0
        }
        let response: Dynamite_SetRecurringDndResponse = try await rpc("set_recurring_dnd", request)
        if response.hasUserStatus {
            continuation.yield(.ownStatusChanged(DynamiteMapper.ownStatus(response.userStatus)))
        }
    }
}
