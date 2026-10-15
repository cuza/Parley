import Foundation

/// Waits until `condition` holds, checking every 10 ms, for at most `timeout`. A fixed sleep before a check fails on a
/// busy Mac (the full suite, a release build running alongside); this waits only as long as it takes.
@MainActor func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}
