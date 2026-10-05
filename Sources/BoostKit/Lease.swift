import Foundation
import Darwin

/// A record of which processes Boost froze, so a crash cannot leave them frozen.
///
/// Pause is only a good feature if it can never strand anything. Quitting Boost
/// already wakes everything, but a crash or a force quit skips that. Two things
/// cover it: a watchdog that outlives Boost and wakes the recorded processes
/// when it disappears, and a sweep at the next launch for the case where even
/// the watchdog never ran, such as a power cut.
@MainActor
enum Lease {

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Boost/paused.lease")
    }

    private static var watchdogArmed = false

    // MARK: - Pure parts

    /// Process ids are reused after a reboot, so a lease written before one
    /// must be ignored: waking whatever now has that number would be wrong.
    nonisolated static func bootTime() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }

    nonisolated static func serialize(_ pids: Set<pid_t>, boot: Int) -> String {
        (["boot:\(boot)"] + pids.sorted().map { String($0) }).joined(separator: "\n") + "\n"
    }

    nonisolated static func parse(_ text: String, boot: Int) -> Set<pid_t> {
        var lines = text.split(separator: "\n").map(String.init)
        guard let header = lines.first, header == "boot:\(boot)" else { return [] }
        lines.removeFirst()
        return Set(lines.compactMap { pid_t($0) }.filter { $0 > 1 })
    }

    /// Of what the lease names, only what is still stopped needs waking.
    nonisolated static func stranded(lease: Set<pid_t>, stopped: Set<pid_t>) -> [pid_t] {
        lease.intersection(stopped).sorted()
    }

    // MARK: - File

    static func write(_ pids: Set<pid_t>, at url: URL = Lease.url) {
        if pids.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? serialize(pids, boot: bootTime()).write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(at url: URL = Lease.url) -> Set<pid_t> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text, boot: bootTime())
    }

    /// Run once at launch, before anything else touches processes.
    @discardableResult
    static func recoverStranded() -> Int {
        let lease = read()
        guard !lease.isEmpty else { try? FileManager.default.removeItem(at: url); return 0 }
        let stopped = Set(SystemScan.sampleProcesses().filter { $0.value.stopped }.keys)
        let toWake = stranded(lease: lease, stopped: stopped)
        for pid in toWake { kill(pid, SIGCONT) }
        try? FileManager.default.removeItem(at: url)
        return toWake.count
    }

    // MARK: - Watchdog

    /// A small shell loop that waits for Boost to exit, however it exits, and
    /// then wakes whatever the lease still names. Waking a process that is not
    /// stopped does nothing, so a stale entry is harmless.
    static func armWatchdog() {
        guard !watchdogArmed else { return }
        watchdogArmed = true

        let script = """
        boost="$1"; lease="$2"
        while kill -0 "$boost" 2>/dev/null; do sleep 2; done
        [ -f "$lease" ] || exit 0
        tail -n +2 "$lease" | while read -r p; do kill -CONT "$p" 2>/dev/null; done
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "boost-watchdog",
                          String(ProcessInfo.processInfo.processIdentifier), url.path]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { watchdogArmed = false }
    }
}
