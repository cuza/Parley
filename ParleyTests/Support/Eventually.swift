import Foundation
import Testing

/// Waits until `condition` holds, checking every 10 ms, for at most `timeout`; if it never does, records an issue at the
/// caller. A fixed sleep before a check fails on a busy Mac (the full suite, a release build running alongside); this
/// waits only as long as it takes.
@MainActor func eventually(
    timeout: Duration = .seconds(3), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("The condition didn't hold within \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
