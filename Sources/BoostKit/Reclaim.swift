import Foundation

/// Gives memory back without closing anything.
///
/// macOS has no call that says "trim everyone's working set" — the Windows tools
/// people know this feature from use `NtSetSystemInformation`, and there is no
/// equivalent here. What macOS does have is a reclaim path it runs itself when
/// memory gets scarce: file-backed pages are evicted, idle anonymous pages are
/// compressed, working sets shrink. The only way to trigger that deliberately is
/// to make memory scarce, briefly, on purpose.
///
/// `/usr/bin/memory_pressure -l warn` does exactly that: it allocates until the
/// system posts a low-memory notification, which is the signal the reclaim path
/// waits for. Killing it hands all of that allocation straight back, and what
/// the rest of the system released stays released.
///
/// Measured on a 16 GB machine at 0.32 GB free: 1.43 GB returned, active and
/// inactive down 1.7 GB between them, and swap unchanged — reclaimed from idle
/// pages rather than paged to disk.
///
/// ## Why this is dangerous, and what stops it
///
/// The mechanism is *allocating memory on a machine that is short of it*. Pushed
/// too far it does the exact thing it is meant to prevent: paging to disk, or in
/// the worst case having the kernel start killing things. So:
///
/// - It refuses to start without headroom to work with.
/// - It watches swap while running and stops the instant swap grows. Paging is
///   the failure, not a cost worth paying for a better-looking number.
/// - It is bounded by a hard timeout regardless.
///
/// This is why the feature is not simply "run the command and report the
/// difference".
enum Reclaim {

    struct Outcome: Sendable {
        /// Bytes that stopped being spoken for.
        ///
        /// Measured as the fall in `used` — active plus wired plus compressed —
        /// and deliberately not as the rise in `free`. Free is volatile: macOS
        /// hands reclaimed pages straight back out as cache, so a run that
        /// genuinely released half a gigabyte can leave `free` slightly lower
        /// than it started. Measured that way this feature reports "nothing to
        /// free" while having worked, which is how a number ends up lying by
        /// accident rather than by design.
        var freed: Int64 = 0
        /// True when it stopped early because the Mac started paging.
        var stoppedOnSwap = false
        /// True when there was not enough headroom to try safely.
        var refused = false
        var seconds: Double = 0
    }

    /// Below this there is not enough slack to allocate into without risking the
    /// paging this is supposed to avoid.
    static let minimumHeadroom: UInt64 = 512 * 1_048_576

    /// Long enough for the reclaim path to run, short enough that a machine
    /// behaving unexpectedly is not held under pressure. Trimmed from an
    /// earlier 8s: with runSeries() now able to run a second pass, the
    /// per-pass budget doesn't need to be as generous, and a button whose
    /// whole job is "quick, before you notice" earns those seconds back
    /// directly as feeling faster to press.
    static let timeout: TimeInterval = 6

    /// Whether it is safe to try at all, given a reading.
    static func hasHeadroom(_ mem: MemStats) -> Bool {
        mem.free + mem.cached >= minimumHeadroom
    }

    /// Runs the reclaim. Blocking and slow — call it off the main actor.
    ///
    /// `sample` is injected so the decision loop can be tested without a real
    /// machine under pressure.
    static func run(sample: () -> MemStats = { SystemScan.memoryNonIsolated() },
                           launch: () -> Process? = { defaultLaunch() }) -> Outcome {
        var outcome = Outcome()
        let before = sample()

        guard hasHeadroom(before) else {
            outcome.refused = true
            return outcome
        }

        guard let process = launch() else { return outcome }
        let started = Date()

        // Poll rather than just sleeping: the whole point is to be able to stop
        // the moment this starts costing more than it returns.
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.4)
            let now = sample()

            if now.swapUsed > before.swapUsed {
                outcome.stoppedOnSwap = true
                break
            }
            if Date().timeIntervalSince(started) >= timeout { break }
        }

        process.terminate()
        process.waitUntilExit()
        outcome.seconds = Date().timeIntervalSince(started)

        // Let the pages it handed back settle before reading.
        Thread.sleep(forTimeInterval: 1.0)
        let after = sample()
        outcome.freed = Int64(bitPattern: before.used) - Int64(bitPattern: after.used)
        return outcome
    }

    /// Runs `run()` repeatedly, back to back, while conditions stay safe.
    ///
    /// One pass rarely drains everything actually reclaimable inside its
    /// own short timeout — the system's reclaim path is often still
    /// unwinding when that pass's process gets killed. A second pass run
    /// immediately after routinely finds more still sitting there. This
    /// doesn't raise the risk per pass: each one still runs the same
    /// headroom check and the same instant stop on swap growth as a lone
    /// call to `run()` would. It just keeps going, safely, instead of
    /// declaring victory after the first short window.
    static func runSeries(maxPasses: Int = 2,
                          sample: () -> MemStats = { SystemScan.memoryNonIsolated() },
                          launch: () -> Process? = { defaultLaunch() }) -> Outcome {
        var total = Outcome()
        for i in 0..<maxPasses {
            let pass = run(sample: sample, launch: launch)
            if i == 0 { total.refused = pass.refused }
            total.freed += pass.freed
            total.seconds += pass.seconds
            if pass.stoppedOnSwap { total.stoppedOnSwap = true; break }
            if pass.refused { break }
            // Diminishing returns, checked after the very first pass: a
            // third pass earned its keep in testing far less often than a
            // second one did, and every extra pass costs real wall-clock
            // time waiting on this button. Two passes is the point where
            // more attempts stopped being worth the wait.
            if pass.freed < 100 * 1_048_576 { break }
        }
        return total
    }

    /// `warn` asks for reclaim; `critical` pushes hard enough that the
    /// kernel can decide to start killing something on its own. `critical`
    /// only ever runs when the person using this app opted into it by hand
    /// in Settings — never a default this picks for them.
    static func defaultLaunch(level: String = "warn") -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        p.arguments = ["-l", level, "-Q"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        return p
    }
}
