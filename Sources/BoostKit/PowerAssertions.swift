import Foundation
import IOKit.pwr_mgt

/// Processes that have asked macOS to stay awake for them.
///
/// Playing audio or video, a call, a screen share and many downloads and exports
/// hold one of these. CPU alone cannot tell them from an app that is truly idle,
/// and freezing a song or a download mid-way is exactly the surprise
/// auto-pause must not cause. Reading the list needs no permission.
enum PowerAssertions {

    private static let blocking: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep",
        "PreventSystemSleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
    ]

    /// Pids that hold a blocking assertion, plus the pids they hold it for.
    /// Audio is the second case: coreaudiod holds the assertion on behalf of
    /// the app that is playing.
    static func busyPIDs() -> Set<pid_t> {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let raw else { return [] }
        let table = raw.takeRetainedValue() as NSDictionary
        return parse(table)
    }

    /// Split out so the reading of the table can be tested with a made-up one.
    static func parse(_ table: NSDictionary) -> Set<pid_t> {
        var out = Set<pid_t>()
        for (key, value) in table {
            guard let pid = (key as? NSNumber)?.int32Value,
                  let assertions = value as? [[String: Any]] else { continue }
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String, blocking.contains(type) else { continue }
                out.insert(pid)
                if let behalf = assertion["AssertionOnBehalfOfPID"] as? NSNumber {
                    out.insert(behalf.int32Value)
                }
            }
        }
        return out
    }
}
