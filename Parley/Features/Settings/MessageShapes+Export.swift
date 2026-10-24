import AppKit
import ParleyDomain
import UniformTypeIdentifiers

extension MessageShapes {
    /// Settings ▸ Advanced ▸ Copy Summary: the summary lines on the clipboard.
    @MainActor static func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            summary(shared.withLock { $0.entries }).joined(separator: "\n"), forType: .string)
    }

    /// Settings ▸ Advanced ▸ Export…: a JSON file to send to the developer, or a note when there is none.
    @MainActor static func saveExport() {
        let entries = shared.withLock { $0.entries }
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No unsupported message shapes"
            alert.informativeText =
                "Parley has drawn every message it loaded since it opened. Try again after one shows up wrong."
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Parley message shapes \(Date.now.formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let info = Bundle.main.infoDictionary
        let app =
            "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        do {
            try export(entries, app: app, os: ProcessInfo.processInfo.operatingSystemVersionString, date: .now).write(
                to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
