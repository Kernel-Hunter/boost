import Testing
import Foundation
@testable import BoostKit

@Suite("Memory history")
struct MemoryHistoryTests {

    private func sample(_ usedGB: Double, swapGB: Double = 0, at offset: TimeInterval = 0) -> MemorySample {
        MemorySample(at: Date(timeIntervalSince1970: 1_000_000 + offset),
                     used: UInt64(usedGB * 1_073_741_824),
                     cached: 0,
                     swap: UInt64(swapGB * 1_073_741_824),
                     pressure: min(1, usedGB / 16))
    }

    /// An app that watches memory must not be the thing leaking it.
    @Test("Never grows past its bound, however long it runs")
    func isBounded() {
        var h = MemoryHistory()
        for i in 0..<(MemoryHistory.capacity * 3) {
            h.record(sample(8, at: Double(i)))
        }
        #expect(h.count == MemoryHistory.capacity)
    }

    @Test("Keeps the newest readings, discards the oldest")
    func keepsNewest() {
        var h = MemoryHistory()
        for i in 0..<(MemoryHistory.capacity + 10) {
            h.record(sample(Double(i % 16), at: Double(i)))
        }
        #expect(h.latest?.at == Date(timeIntervalSince1970: 1_000_000 + Double(MemoryHistory.capacity + 9)))
    }

    @Test("Says nothing at all until it has enough to say")
    func refusesToGuessEarly() {
        var h = MemoryHistory()
        for i in 0..<5 { h.record(sample(4 + Double(i), at: Double(i * 4))) }
        #expect(h.trend() == nil)
    }

    @Test("Reports a genuine climb")
    func reportsGrowth() {
        var h = MemoryHistory()
        for i in 0..<40 { h.record(sample(4 + Double(i) * 0.15, at: Double(i * 4))) }
        let t = h.trend()
        #expect(t?.hasPrefix("Up ") == true)
    }

    @Test("Reports a genuine fall")
    func reportsShrink() {
        var h = MemoryHistory()
        for i in 0..<40 { h.record(sample(10 - Double(i) * 0.15, at: Double(i * 4))) }
        #expect(h.trend()?.hasPrefix("Down ") == true)
    }

    /// Calling ordinary drift a trend trains people to ignore the one line that
    /// would have mattered.
    @Test("Small drift is steady, not a trend")
    func ignoresNoise() {
        var h = MemoryHistory()
        for i in 0..<40 {
            h.record(sample(8 + (i % 2 == 0 ? 0.01 : -0.01), at: Double(i * 4)))
        }
        #expect(h.trend()?.hasPrefix("Steady") == true)
    }

    @Test("Swap appearing outranks everything else")
    func swapStartingWins() {
        var h = MemoryHistory()
        for i in 0..<20 { h.record(sample(8, swapGB: 0, at: Double(i * 4))) }
        for i in 20..<40 { h.record(sample(8, swapGB: 1, at: Double(i * 4))) }
        #expect(h.swapStarted)
        #expect(h.trend() == "Swap started during this session.")
    }

    @Test("Swap that was already there is not an event")
    func preexistingSwapIsNotNews() {
        var h = MemoryHistory()
        for i in 0..<40 { h.record(sample(8, swapGB: 2, at: Double(i * 4))) }
        #expect(!h.swapStarted)
    }

    @Test("An empty history answers without crashing")
    func emptyIsSafe() {
        let h = MemoryHistory()
        #expect(h.latest == nil)
        #expect(h.trend() == nil)
        #expect(h.usedDelta == 0)
        #expect(h.peakUsed == 0)
        #expect(!h.swapStarted)
    }
}

@Suite("Per-app growth")
struct AppGrowthTests {

    private let mb: UInt64 = 1_048_576

    @Test("Flags an app whose floor keeps rising")
    func flagsSteadyClimb() {
        var g = AppGrowth()
        for i in 0..<40 { g.record([(id: "leaky", bytes: UInt64(500 + i * 40) * 1_048_576)]) }
        #expect(g.growth(of: "leaky") != nil)
    }

    /// A browser is supposed to be big. Big is not the signal; never giving any
    /// back is.
    @Test("Leaves a large but stable app alone")
    func ignoresLargeButSteady() {
        var g = AppGrowth()
        for _ in 0..<40 { g.record([(id: "browser", bytes: 4096 * 1_048_576)]) }
        #expect(g.growth(of: "browser") == nil)
    }

    @Test("Leaves an app that rises and falls alone")
    func ignoresSawtooth() {
        var g = AppGrowth()
        for i in 0..<40 {
            g.record([(id: "worker", bytes: UInt64(1000 + (i % 4) * 100) * 1_048_576)])
        }
        #expect(g.growth(of: "worker") == nil)
    }

    @Test("Says nothing before it has watched long enough")
    func refusesEarly() {
        var g = AppGrowth()
        for i in 0..<5 { g.record([(id: "x", bytes: UInt64(100 + i * 500) * 1_048_576)]) }
        #expect(g.growth(of: "x") == nil)
    }

    @Test("An app that exits stops being tracked")
    func forgetsDeadApps() {
        var g = AppGrowth()
        for _ in 0..<10 { g.record([(id: "gone", bytes: 500 * 1_048_576)]) }
        #expect(g.samples(for: "gone") == 10)
        g.record([(id: "other", bytes: 100 * 1_048_576)])
        #expect(g.samples(for: "gone") == 0)
    }

    /// The id has the pid appended when several live processes share a bundle,
    /// so a restarted app is a new series rather than a continuation with a
    /// false slope across the gap.
    @Test("Never grows past its window")
    func isBounded() {
        var g = AppGrowth()
        for i in 0..<(AppGrowth.window * 2) {
            g.record([(id: "x", bytes: UInt64(i) * 1_048_576)])
        }
        #expect(g.samples(for: "x") == AppGrowth.window)
    }
}

@Suite("Growth detection is about the floor")
struct AppGrowthFloorTests {

    /// Regression: comparing the lowest reading ever against the latest flagged
    /// any app that swings wider than the threshold, whenever a sample landed
    /// near the top of a swing.
    @Test("A wide but repeating swing is not growth")
    func wideSawtoothIsNotGrowth() {
        var g = AppGrowth()
        for i in 0..<60 {
            // Swings 1 GB, returns to the same floor every cycle.
            let mb = 1000 + (i % 5) * 250
            g.record([(id: "swingy", bytes: UInt64(mb) * 1_048_576)])
        }
        #expect(g.growth(of: "swingy") == nil)
    }

    /// The same swing, but the whole thing drifts upward — the floor never
    /// returns. That is the shape worth reporting.
    @Test("A swing whose floor rises is growth")
    func risingFloorIsGrowth() {
        var g = AppGrowth()
        for i in 0..<60 {
            let mb = 1000 + (i % 5) * 250 + i * 20
            g.record([(id: "leaky", bytes: UInt64(mb) * 1_048_576)])
        }
        #expect(g.growth(of: "leaky") != nil)
    }
}
