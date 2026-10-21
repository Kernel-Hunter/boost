import Testing
import Foundation
@testable import BoostKit

private let gb: UInt64 = 1_073_741_824

@Suite("Memory report")
struct MemoryReportTests {
    private let machine = MemoryReport.Machine(os: "macOS 15.1", model: "Mac15,3", chip: "Apple M3")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mem(used: UInt64 = 11 * gb, swap: UInt64 = 0) -> MemStats {
        MemStats(total: 16 * gb, used: used, cached: 3 * gb, free: gb, compressed: 4 * gb, swapUsed: swap)
    }

    @Test("States the figures a helper asks for first")
    func headlineFigures() {
        let text = MemoryReport.text(version: "1.3.0", machine: machine, mem: mem(), apps: [],
                                     pausedCount: 0, history: nil, now: now)
        #expect(text.contains("Boost 1.3.0 memory report"))
        #expect(text.contains("macOS 15.1, Mac15,3, Apple M3, 16.00 GB"))
        #expect(text.contains("Pressure 68% (plenty of headroom)"))
        #expect(text.contains("In use 11.00 GB of 16.00 GB"))
        #expect(text.contains("Cached 3.00 GB, compressed 4.00 GB, swap none"))
    }

    @Test("Names swap and the level when memory is tight")
    func swapAndLevel() {
        let text = MemoryReport.text(version: "1.3.0", machine: machine,
                                     mem: mem(used: 15 * gb, swap: 2 * gb), apps: [],
                                     pausedCount: 0, history: nil, now: now)
        #expect(text.contains("(under pressure)"))
        #expect(text.contains("swap 2.00 GB"))
    }

    @Test("Lists apps by name and size, and nothing that identifies the person")
    func appsOnly() {
        let apps = [MemoryReport.App(name: "Safari", bytes: 700 * 1_048_576),
                    MemoryReport.App(name: "Claude", bytes: 4 * gb)]
        let text = MemoryReport.text(version: "1.3.0", machine: machine, mem: mem(), apps: apps,
                                     pausedCount: 2, history: nil, now: now)
        #expect(text.contains("Biggest apps\n  Safari 700 MB\n  Claude 4.00 GB"))
        #expect(text.contains("Paused apps: 2"))
        #expect(!text.contains("/Users"))
        #expect(!text.contains(NSUserName()))
    }

    @Test("Leaves the paused line out when nothing is paused")
    func noPausedLine() {
        let text = MemoryReport.text(version: "1.3.0", machine: machine, mem: mem(), apps: [],
                                     pausedCount: 0, history: nil, now: now)
        #expect(!text.contains("Paused apps"))
    }

    @Test("Says nothing about history until there is enough of it")
    func shortHistory() {
        var history = LongHistory()
        history.record(at: now.addingTimeInterval(-60), pressure: 0.5, swapBytes: 0)
        #expect(MemoryReport.historySummary(history, now: now) == nil)
    }

    @Test("Summarises the last day once it has readings")
    func daySummary() throws {
        var history = LongHistory()
        for m in 0..<30 {
            history.record(at: now.addingTimeInterval(Double(m - 30) * 60),
                           pressure: m == 10 ? 0.9 : 0.6, swapBytes: m == 10 ? 1_500_000_000 : 0)
        }
        let summary = try #require(MemoryReport.historySummary(history, now: now))
        #expect(summary.hasPrefix("Last 24 hours: peak 90% at "))
        #expect(summary.contains("swap appeared 1 time"))
    }

    @Test("Reads this machine without trouble")
    func currentMachineIsFilled() {
        let m = MemoryReport.currentMachine()
        #expect(m.os.hasPrefix("macOS "))
    }
}
