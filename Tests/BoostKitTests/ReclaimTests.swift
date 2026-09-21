import Testing
import Foundation
@testable import BoostKit

/// Reclaiming works by allocating memory on a machine that is already short of
/// it. Every test here is about the brakes, because the mechanism without them
/// causes the exact problem it exists to solve.
@Suite("Reclaim safety")
struct ReclaimTests {

    private func mem(freeGB: Double = 2, cachedGB: Double = 2, swapGB: Double = 0) -> MemStats {
        var m = MemStats()
        m.total = 16 * 1_073_741_824
        m.free = UInt64(freeGB * 1_073_741_824)
        m.cached = UInt64(cachedGB * 1_073_741_824)
        m.swapUsed = UInt64(swapGB * 1_073_741_824)
        return m
    }

    // MARK: - Refusing to start

    @Test("Runs when there is room to work with")
    func runsWithHeadroom() {
        #expect(Reclaim.hasHeadroom(mem(freeGB: 2, cachedGB: 2)))
    }

    /// Allocating into a machine with nothing spare is how this turns into the
    /// paging it is meant to prevent.
    @Test("Refuses when there is nothing spare")
    func refusesWithoutHeadroom() {
        #expect(!Reclaim.hasHeadroom(mem(freeGB: 0.1, cachedGB: 0.1)))
    }

    @Test("Counts cache as headroom — it is reclaimable by definition")
    func cacheCountsAsHeadroom() {
        #expect(Reclaim.hasHeadroom(mem(freeGB: 0.05, cachedGB: 4)))
    }

    @Test("A refusal does nothing at all")
    func refusalLaunchesNothing() {
        var launched = false
        let outcome = Reclaim.run(
            sample: { self.mem(freeGB: 0.05, cachedGB: 0.05) },
            launch: { launched = true; return nil })
        #expect(outcome.refused)
        #expect(!launched, "nothing should be started when we already decided not to")
        #expect(outcome.freed == 0)
    }

    // MARK: - Stopping

    /// The whole justification for this feature is that it reclaims from idle
    /// pages rather than writing them to disk. The moment swap grows, it is no
    /// longer doing that and must stop, whatever the free figure is doing.
    @Test("Stops the instant the Mac starts paging")
    func stopsOnSwapGrowth() {
        var reading = 0
        let outcome = Reclaim.run(
            sample: { [self] in
                reading += 1
                // First reading is the baseline; from the second, swap is climbing.
                return mem(freeGB: 2, cachedGB: 2, swapGB: reading <= 1 ? 0 : 1)
            },
            launch: { sleeper(seconds: 30) })

        #expect(outcome.stoppedOnSwap)
        #expect(outcome.seconds < Reclaim.timeout,
                "should have given up long before the timeout")
    }

    @Test("Gives up at the timeout even when nothing goes wrong")
    func stopsAtTimeout() {
        let outcome = Reclaim.run(
            sample: { self.mem(freeGB: 2, cachedGB: 2, swapGB: 0) },
            launch: { sleeper(seconds: 30) })

        #expect(!outcome.stoppedOnSwap)
        #expect(outcome.seconds >= Reclaim.timeout)
        #expect(outcome.seconds < Reclaim.timeout + 3, "should not overrun by much")
    }

    /// If the tool is missing or cannot start, that is a quiet no-op rather than
    /// a crash or a fabricated result.
    @Test("A launch that fails reports nothing freed")
    func failedLaunchIsQuiet() {
        let outcome = Reclaim.run(sample: { self.mem() }, launch: { nil })
        #expect(outcome.freed == 0)
        #expect(!outcome.refused)
    }

    /// Regression: this measured the rise in `free` rather than the fall in
    /// `used`. macOS hands reclaimed pages straight back out as cache, so a run
    /// that released half a gigabyte could leave `free` *lower* than it started
    /// — and the feature reported "nothing to free" having just worked.
    /// Observed on a real machine: used 9.67 GB -> 9.14 GB, free 2.62 -> 2.55.
    @Test("Counts memory that stopped being used, not memory that looks free")
    func measuresUsedNotFree() {
        var reading = 0
        let outcome = Reclaim.run(
            sample: {
                reading += 1
                var m = MemStats()
                m.total = 16 * 1_073_741_824
                if reading == 1 {
                    m.used = UInt64(9.67 * 1_073_741_824)
                    m.free = UInt64(2.62 * 1_073_741_824)
                    m.cached = 2 * 1_073_741_824
                } else {
                    // Half a gigabyte genuinely released, and free went *down*.
                    m.used = UInt64(9.14 * 1_073_741_824)
                    m.free = UInt64(2.55 * 1_073_741_824)
                    m.cached = 2 * 1_073_741_824
                }
                return m
            },
            // A process that exits on its own, so the loop finishes and the
            // after-reading happens; only the arithmetic is under test.
            launch: { self.sleeper(seconds: 1) })

        #expect(outcome.freed > 500 * 1_048_576,
                "should report the half gigabyte that stopped being used")
    }

    /// Stands in for memory_pressure: something that stays running until killed,
    /// so the loop's own stopping conditions are what end it.
    private func sleeper(seconds: Int) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["\(seconds)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return p
    }
}

/// Free Memory used to stop after one short pass, which routinely left
/// memory on the table that a second pass would have caught mid-unwind.
/// These tests are about the orchestration on top of `run()` — the safety
/// behaviour itself (headroom, swap, timeout) is already covered above and
/// unchanged; a series is just that same, already-tested unit of work,
/// repeated while it keeps paying off.
@Suite("Reclaim series")
struct ReclaimSeriesTests {

    private func mem(freeGB: Double = 2, cachedGB: Double = 2,
                     swapGB: Double = 0, usedGB: Double = 10) -> MemStats {
        var m = MemStats()
        m.total = 16 * 1_073_741_824
        m.free = UInt64(freeGB * 1_073_741_824)
        m.cached = UInt64(cachedGB * 1_073_741_824)
        m.swapUsed = UInt64(swapGB * 1_073_741_824)
        m.used = UInt64(usedGB * 1_073_741_824)
        return m
    }

    private func sleeper(seconds: Double) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["\(seconds)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return p
    }

    @Test("Sums what multiple passes freed, rather than reporting only the first")
    func accumulatesAcrossPasses() {
        var usedGB = 10.0
        let outcome = Reclaim.runSeries(
            maxPasses: 3,
            sample: { [self] in
                defer { usedGB -= 0.5 }
                return mem(usedGB: usedGB)
            },
            launch: { self.sleeper(seconds: 0.1) })
        // Headroom and swap stay fine throughout, and every reading frees
        // more than the last, so all three passes should run — reporting
        // more, together, than any single one of them could alone.
        #expect(outcome.freed > 2 * 1_073_741_824,
                "three passes should sum to more than one pass's worth")
    }

    @Test("Swap growing on any pass stops the whole series, not just that pass")
    func swapGrowthStopsTheSeries() {
        var launches = 0
        var callCount = 0
        let outcome = Reclaim.runSeries(
            maxPasses: 5,
            sample: { [self] in
                callCount += 1
                return mem(swapGB: Double(callCount) * 0.2)   // keeps climbing every reading
            },
            launch: { launches += 1; return self.sleeper(seconds: 0.3) })
        #expect(outcome.stoppedOnSwap)
        #expect(launches == 1, "should not attempt a second pass once swap started climbing")
    }

    @Test("A refusal on the very first pass stops the whole series")
    func refusalStopsTheSeries() {
        var launches = 0
        let outcome = Reclaim.runSeries(
            maxPasses: 3,
            sample: { self.mem(freeGB: 0.05, cachedGB: 0.05) },
            launch: { launches += 1; return self.sleeper(seconds: 0.1) })
        #expect(outcome.refused)
        #expect(launches == 0, "nothing should be started when the first pass already refused")
    }
}

/// What it says afterwards matters as much as what it does. Reporting a
/// flattering number for a thing that did not happen is the house style of the
/// category this app is trying not to be part of.
@MainActor
@Suite("What freeing memory reports")
struct ReclaimReportTests {

    private func outcome(freed: Int64 = 0, swap: Bool = false,
                         refused: Bool = false) -> Reclaim.Outcome {
        var o = Reclaim.Outcome()
        o.freed = freed
        o.stoppedOnSwap = swap
        o.refused = refused
        return o
    }

    @Test("Says how much, when there was some")
    func reportsRealGain() {
        let text = Engine.describe(outcome(freed: 2 * 1_073_741_824))
        #expect(text.contains("Freed"))
        #expect(text.contains("2.00 GB"))
    }

    @Test("Says nothing happened, rather than inventing a figure")
    func reportsNothing() {
        let text = Engine.describe(outcome(freed: 0))
        #expect(text.contains("Nothing to free"))
    }

    /// A few megabytes is noise. Calling it a win teaches people the number is
    /// theatre, which it would then be.
    @Test("Does not dress up noise as a result")
    func ignoresNoise() {
        let text = Engine.describe(outcome(freed: 4 * 1_048_576))
        #expect(text.contains("Nothing to free"))
    }

    @Test("Explains a refusal instead of failing silently")
    func explainsRefusal() {
        let text = Engine.describe(outcome(refused: true))
        #expect(text.lowercased().contains("not enough spare memory"))
        #expect(text.contains("pause") || text.contains("Close"))
    }

    @Test("Admits when it stopped because the Mac started paging")
    func admitsPaging() {
        let partial = Engine.describe(outcome(freed: 2 * 1_073_741_824, swap: true))
        #expect(partial.contains("Freed"))
        #expect(partial.lowercased().contains("paging"))

        let none = Engine.describe(outcome(freed: 0, swap: true))
        #expect(none.lowercased().contains("paging"))
    }

    @Test("Appends the purge note when purging also ran")
    func includesPurgeNote() {
        let text = Engine.describe(outcome(freed: 2 * 1_073_741_824),
                                   purgeNote: "Disk cache purged.")
        #expect(text.contains("Disk cache purged."))
    }
}
