import Foundation
import Testing

/// Errors reach the system log as public text only through `ConnectionDiagnostics.redact`, which takes out what could be
/// personal (addresses, ids, query strings). A new log line that skips it fails here.
struct LoggingGuardTests {
    @Test func publicErrorLogsAreRedacted() throws {
        let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Parley")
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        let raw = [#"\(error.localizedDescription, privacy: .public)"#, #"\(String(describing: error), privacy: .public)"#]
        let offenders = try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").enumerated()
                .filter { _, line in raw.contains { line.contains($0) } }
                .map { "\(file.lastPathComponent):\($0.offset + 1)" }
        }
        #expect(offenders.isEmpty, "log through ConnectionDiagnostics.redact: \(offenders)")
    }
}
