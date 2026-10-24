import Foundation
import ParleyDomain

extension ChatStore {
    func setDoNotDisturb(for duration: TimeInterval) async {
        await setOwnStatus { try await $0.setDoNotDisturb(for: duration) }
    }
    func setAway(_ away: Bool) async { await setOwnStatus { try await $0.setAway(away) } }
    func setCustomStatus(_ status: CustomStatus?) async { await setOwnStatus { try await $0.setCustomStatus(status) } }
    private func setOwnStatus(_ change: (any ChatBackend) async throws -> OwnStatus) async {
        do { ownStatus = try await change(backend) } catch { report(error) }
    }
    func loadDndSchedules() async {
        do { dndSchedules = try await backend.dndSchedules(timeZone: TimeZone.current.identifier) } catch {
            report(error)
        }
    }
    /// Saves the whole set; on failure the old one stays.
    func saveDndSchedules(_ schedules: DndSchedules) async {
        let old = dndSchedules
        // An alert: the hours just set in the sheet are gone.
        await optimistically(.alert) {
            dndSchedules = schedules
        } undo: {
            dndSchedules = old
        } send: {
            try await backend.setDndSchedules(schedules)
        }
    }
}
