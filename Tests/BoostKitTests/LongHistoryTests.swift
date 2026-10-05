import Testing
import Foundation
@testable import BoostKit

private let gb: UInt64 = 1_073_741_824

// MARK: - Long history

@Suite("Long history")
struct LongHistoryTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func filled(minutes: Int, pressure: (Int) -> Double = { _ in 0.5 },
                        swap: (Int) -> UInt64 = { _ in 0 }) -> LongHistory {
        var h = LongHistory()
        for m in 0..<minutes {
            h.record(at: base.addingTimeInterval(Double(m) * 60), pressure: pressure(m), swapBytes: swap(m))
        }
        return h
    }

    @Test("Stores one reading a minute and ignores the rest")
    func oneAMinute() {
        var h = LongHistory()
        let first = h.record(at: base, pressure: 0.5, swapBytes: 0)
        let tooSoon = h.record(at: base.addingTimeInterval(30), pressure: 0.9, swapBytes: 0)
        let next = h.record(at: base.addingTimeInterval(61), pressure: 0.6, swapBytes: 0)
        #expect(first)
        #expect(!tooSoon)
        #expect(next)
        #expect(h.count == 2)
    }

    @Test("Never grows past a week")
    func bounded() {
        let h = filled(minutes: LongHistory.capacity + 500)
        #expect(h.count == LongHistory.capacity)
    }

    @Test("A clock that moves backwards drops the readings from the future and keeps recording")
    func clockBackwards() {
        var h = filled(minutes: 10)                       // 0 ... 9 minutes
        let rewound = base.addingTimeInterval(3 * 60 + 5)
        h.record(at: rewound, pressure: 0.4, swapBytes: 0)
        let next = h.record(at: rewound.addingTimeInterval(65), pressure: 0.4, swapBytes: 0)
        #expect(next)
        #expect(h.count == 5)                             // minutes 0 ... 3, then the new one
        #expect(h.samples.last?.date == rewound.addingTimeInterval(65))
    }

    @Test("Survives being written to disk and read back")
    func roundTrip() {
        let h = filled(minutes: 200, pressure: { Double($0 % 100) / 100 }, swap: { $0 % 7 == 0 ? 3 * gb : 0 })
        let back = LongHistory(data: h.encoded())
        #expect(back?.samples == h.samples)
    }

    @Test("Refuses a file that is not ours, rather than half reading it")
    func rejectsGarbage() {
        #expect(LongHistory(data: Data("not a history".utf8)) == nil)
        var truncated = filled(minutes: 20).encoded()
        truncated.removeLast(3)
        #expect(LongHistory(data: truncated) == nil)
        #expect(LongHistory(data: Data()) == nil)
    }

    @Test("Names the worst moment in the window")
    func peak() {
        let h = filled(minutes: 120, pressure: { $0 == 40 ? 0.97 : 0.5 })
        let now = base.addingTimeInterval(120 * 60)
        let peak = h.peak(in: .twoHours, now: now)
        #expect(peak?.pressure == 0.97)
        #expect(peak?.at == base.addingTimeInterval(40 * 60))
    }

    @Test("Only counts readings inside the range asked for")
    func windowing() {
        let h = filled(minutes: 600, pressure: { $0 < 300 ? 0.95 : 0.4 })
        let now = base.addingTimeInterval(600 * 60)
        #expect(h.peak(in: .twoHours, now: now)?.pressure == 0.4)
        #expect(h.peak(in: .day, now: now)?.pressure == 0.95)
    }

    @Test("Counts swap appearing, not swap that was already there")
    func swapEpisodes() {
        // Present from the start, gone, back, gone, back: two arrivals.
        let h = filled(minutes: 60, swap: { m in
            (m < 5 || (20..<30).contains(m) || m >= 50) ? gb : 0
        })
        let now = base.addingTimeInterval(60 * 60)
        #expect(h.swapEpisodes(in: .twoHours, now: now) == 2)
    }

    @Test("Reducing a long window keeps the spike instead of averaging it away")
    func bucketsKeepPeaks() {
        let h = filled(minutes: 7 * 24 * 60, pressure: { $0 == 5000 ? 0.99 : 0.3 })
        let now = base.addingTimeInterval(Double(7 * 24 * 60) * 60)
        let points = h.points(for: .week, now: now, buckets: 100)
        #expect(points.count <= 100)
        #expect(points.map(\.pressure).max() == 0.99)
    }

    @Test("Marks buckets in which swap was in use")
    func bucketsKeepSwap() {
        let h = filled(minutes: 3000, swap: { $0 == 1500 ? gb : 0 })
        let now = base.addingTimeInterval(3000 * 60)
        let points = h.points(for: .week, now: now, buckets: 50)
        #expect(points.contains { $0.swapped })
    }

    @Test("Saves to and loads from a file")
    func store() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boost-history-\(UUID().uuidString)/history.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let h = filled(minutes: 30)
        HistoryStore.save(h, to: url)
        #expect(HistoryStore.load(from: url).samples == h.samples)
        #expect(HistoryStore.load(from: url.appendingPathExtension("missing")).isEmpty)
    }
}

// MARK: - Lease

@MainActor
@Suite("Pause lease")
struct LeaseTests {

    @Test("Round trips the processes it names")
    func roundTrip() {
        let text = Lease.serialize([4021, 88, 903], boot: 1_700_000_000)
        #expect(Lease.parse(text, boot: 1_700_000_000) == [88, 903, 4021])
    }

    @Test("Ignores a lease written before the last reboot")
    func staleAfterReboot() {
        let text = Lease.serialize([4021], boot: 1_700_000_000)
        #expect(Lease.parse(text, boot: 1_700_009_999).isEmpty)
    }

    @Test("Never names the system's own processes")
    func skipsLow() {
        let text = "boot:5\n0\n1\n-3\nabc\n77\n"
        #expect(Lease.parse(text, boot: 5) == [77])
    }

    @Test("Wakes only what is still stopped")
    func onlyStopped() {
        #expect(Lease.stranded(lease: [10, 20, 30], stopped: [20, 30, 99]) == [20, 30])
    }

    @Test("Writes nothing, and removes the file, when nothing is paused")
    func emptyLeaseRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boost-lease-\(UUID().uuidString)")
        Lease.write([123], at: url)
        #expect(Lease.read(at: url) == [123])
        Lease.write([], at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Auto-pause

@MainActor
@Suite("Auto-pause")
struct AutoPauseTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, cpu: Double = 0.2, paused: Bool = false) -> Item {
        Item(baseID: id, id: id, name: id, category: .app, isAppleSoftware: false,
             pids: [4242], rssBytes: 500 * 1_048_576, rssKnown: true, cpu: cpu,
             isPaused: paused, bundlePath: nil, runningAppPID: nil)
    }

    private func due(_ items: [Item], listed: Set<String>, seen: [String: Date],
                     frontmost: String? = nil, idle: TimeInterval = 600) -> [String] {
        AutoPause.candidates(items: items, listed: listed, lastActive: seen,
                             frontmost: frontmost, now: now, idle: idle).map(\.baseID)
    }

    @Test("Pauses a listed app once it has been idle long enough")
    func pausesWhenIdle() {
        let seen = ["com.tinyspeck.slackmacgap": now.addingTimeInterval(-601)]
        #expect(due([item("com.tinyspeck.slackmacgap")], listed: ["com.tinyspeck.slackmacgap"], seen: seen)
                == ["com.tinyspeck.slackmacgap"])
    }

    @Test("Leaves it alone before the time is up")
    func waits() {
        let seen = ["a": now.addingTimeInterval(-599)]
        #expect(due([item("a")], listed: ["a"], seen: seen).isEmpty)
    }

    @Test("Never touches an app that was not listed")
    func onlyListed() {
        let seen = ["a": now.addingTimeInterval(-9999)]
        #expect(due([item("a")], listed: ["b"], seen: seen).isEmpty)
    }

    @Test("Never pauses the app you are using")
    func notFrontmost() {
        let seen = ["a": now.addingTimeInterval(-9999)]
        #expect(due([item("a")], listed: ["a"], seen: seen, frontmost: "a").isEmpty)
    }

    @Test("Never pauses an app that is busy")
    func notBusy() {
        let seen = ["a": now.addingTimeInterval(-9999)]
        #expect(due([item("a", cpu: 40)], listed: ["a"], seen: seen).isEmpty)
    }

    @Test("Does not pause what is already paused, or what it has never seen")
    func alreadyOrUnseen() {
        let seen = ["a": now.addingTimeInterval(-9999)]
        #expect(due([item("a", paused: true)], listed: ["a"], seen: seen).isEmpty)
        #expect(due([item("b")], listed: ["b"], seen: [:]).isEmpty)
    }

    @Test("Never pauses the desktop, even if it is listed by mistake")
    func protectedStaysProtected() {
        let seen = ["com.apple.finder": now.addingTimeInterval(-9999)]
        #expect(due([item("com.apple.finder")], listed: ["com.apple.finder"], seen: seen).isEmpty)
    }
}

// MARK: - Sustained pressure alert

@MainActor
@Suite("Sustained pressure alert", .serialized)
struct SustainedAlertTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let culprit: (name: String, bytes: UInt64) = ("Chrome", 5 * 1_073_741_824)

    private func fresh() -> Rules {
        let r = Rules.shared
        r.sustainedEnabled = true
        r.sustainedSeconds = 60
        r.resetSustainedForTesting()
        return r
    }

    @Test("Stays quiet for a spike that passes on its own")
    func spike() {
        let r = fresh()
        #expect(!r.evaluateSustained(tight: true, culprit: culprit, now: t0, notify: { _ in }))
        #expect(!r.evaluateSustained(tight: true, culprit: culprit, now: t0.addingTimeInterval(30), notify: { _ in }))
        #expect(!r.evaluateSustained(tight: false, culprit: culprit, now: t0.addingTimeInterval(40), notify: { _ in }))
        #expect(!r.evaluateSustained(tight: true, culprit: culprit, now: t0.addingTimeInterval(50), notify: { _ in }))
    }

    @Test("Speaks once pressure has stayed high, and names the app")
    func fires() {
        let r = fresh()
        var message = ""
        r.evaluateSustained(tight: true, culprit: culprit, now: t0, notify: { _ in })
        let fired = r.evaluateSustained(tight: true, culprit: culprit,
                                        now: t0.addingTimeInterval(61), notify: { message = $0 })
        #expect(fired)
        #expect(message.contains("Chrome"))
        #expect(message.contains("5.00 GB"))
    }

    @Test("Says it once per stretch, not every refresh")
    func onlyOnce() {
        let r = fresh()
        r.evaluateSustained(tight: true, culprit: culprit, now: t0, notify: { _ in })
        #expect(r.evaluateSustained(tight: true, culprit: culprit, now: t0.addingTimeInterval(61), notify: { _ in }))
        #expect(!r.evaluateSustained(tight: true, culprit: culprit, now: t0.addingTimeInterval(90), notify: { _ in }))
    }

    @Test("Does nothing while switched off")
    func off() {
        let r = fresh()
        r.sustainedEnabled = false
        r.evaluateSustained(tight: true, culprit: culprit, now: t0, notify: { _ in })
        #expect(!r.evaluateSustained(tight: true, culprit: culprit, now: t0.addingTimeInterval(500), notify: { _ in }))
    }
}
