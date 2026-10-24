import ParleyDomain
import SwiftUI

/// Settings ▸ Advanced: connection diagnostics, the unsupported-content report, and who I blocked.
struct AdvancedSettings: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        // ponytail: the count is read when Settings draws; it doesn't follow new messages while it is open.
        let kinds = MessageShapes.shared.withLock { $0.entries.count }
        Form {
            BlockedSection()
            Section {
                LabeledContent("Connection") {
                    Button("Connection Diagnostics…") { openWindow(id: "connection-diagnostics") }
                }
            } footer: {
                SettingsFooter("Shows the connection, the saved session and read checks, with a report to copy.")
            }
            Section {
                LabeledContent("Unsupported content") {
                    HStack {
                        Button("Export…") { MessageShapes.saveExport() }
                        Button("Copy Summary") { MessageShapes.copySummary() }
                    }.disabled(kinds == 0)
                }
            } footer: {
                SettingsFooter(
                    "\(kinds) kind\(kinds == 1 ? "" : "s") seen this session. The report lists message content Parley can't draw yet, by field number only, with no text, names or ids."
                )
            }
        }
    }
}
