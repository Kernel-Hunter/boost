import Foundation

/// How far back the history chart looks.
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case twoHours, day, week
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .twoHours: return "2h"
        case .day:      return "24h"
        case .week:     return "7d"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .twoHours: return 2 * 3600
        case .day:      return 24 * 3600
        case .week:     return 7 * 24 * 3600
        }
    }

    var axisLabel: String {
        switch self {
        case .twoHours: return "2 hours ago"
        case .day:      return "24 hours ago"
        case .week:     return "7 days ago"
        }
    }
}

/// One reading per minute, kept small enough to hold a week of them.
public struct LongSample: Equatable, Sendable {
    public var time: UInt32        // seconds since 1970
    public var pressure: UInt8     // 0...100
    public var swapMB: UInt16      // saturates at 65 535

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
}

/// One point on the chart, already reduced to what the drawing needs.
public struct ChartPoint: Equatable, Sendable {
    public let date: Date
    public let pressure: Double    // 0...1
    public let swapped: Bool
}

/// A week of memory pressure, one reading a minute.
///
/// The live graph answers "what is it doing now". Nearly every comparable tool
/// is asked the other question as well: what was it doing while I was away, and
/// did that slowdown at three o'clock have a cause. That needs history that
/// survives quitting the app.
///
/// Bounded: 10 080 readings at seven bytes each is about 70 KB on disk.
public struct LongHistory: Sendable {
    public static let capacity = 7 * 24 * 60
    public static let interval: TimeInterval = 60

    private(set) var samples: [LongSample] = []

    public init() {}

    public var count: Int { samples.count }
    public var isEmpty: Bool { samples.isEmpty }

    // MARK: - Recording

    /// Stores a reading unless one was stored less than a minute ago.
    /// Returns whether it was stored.
    @discardableResult
    public mutating func record(at date: Date, pressure: Double, swapBytes: UInt64) -> Bool {
        let seconds = UInt32(max(0, min(date.timeIntervalSince1970, Double(UInt32.max))))

        // A clock that moved backwards would otherwise block recording until
        // it caught up, and leave readings from the "future" in the chart.
        if let last = samples.last, seconds < last.time {
            samples.removeAll { $0.time > seconds }
        }
        if let last = samples.last, TimeInterval(seconds - last.time) < Self.interval {
            return false
        }

        let percent = UInt8(max(0, min(100, (pressure * 100).rounded())))
        let swap = UInt16(min(UInt64(UInt16.max), swapBytes / 1_048_576))
        samples.append(LongSample(time: seconds, pressure: percent, swapMB: swap))
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
        return true
    }

    public mutating func clear() { samples.removeAll() }

    // MARK: - Reading

    func window(_ range: HistoryRange, now: Date) -> [LongSample] {
        let start = now.timeIntervalSince1970 - range.seconds
        return samples.filter { TimeInterval($0.time) >= start }
    }

    /// The window reduced to at most `buckets` points. Each bucket keeps its
    /// highest pressure, because averaging would hide exactly the spike the
    /// chart is there to show.
    public func points(for range: HistoryRange, now: Date, buckets: Int = 140) -> [ChartPoint] {
        let slice = window(range, now: now)
        guard !slice.isEmpty else { return [] }

        if slice.count <= buckets {
            return slice.map {
                ChartPoint(date: $0.date, pressure: Double($0.pressure) / 100, swapped: $0.swapMB > 0)
            }
        }

        var result: [ChartPoint] = []
        result.reserveCapacity(buckets)
        let size = Double(slice.count) / Double(buckets)
        for b in 0..<buckets {
            let lo = Int(Double(b) * size)
            let hi = min(slice.count, max(lo + 1, Int(Double(b + 1) * size)))
            let part = slice[lo..<hi]
            guard let peak = part.max(by: { $0.pressure < $1.pressure }), let last = part.last else { continue }
            result.append(ChartPoint(date: last.date,
                                     pressure: Double(peak.pressure) / 100,
                                     swapped: part.contains { $0.swapMB > 0 }))
        }
        return result
    }

    public func peak(in range: HistoryRange, now: Date) -> (pressure: Double, at: Date)? {
        guard let top = window(range, now: now).max(by: { $0.pressure < $1.pressure }) else { return nil }
        return (Double(top.pressure) / 100, top.date)
    }

    public func average(in range: HistoryRange, now: Date) -> Double? {
        let slice = window(range, now: now)
        guard !slice.isEmpty else { return nil }
        let total = slice.reduce(0) { $0 + Int($1.pressure) }
        return Double(total) / Double(slice.count) / 100
    }

    /// How many times swap went from nothing to something. Swap that was
    /// already there when the window opened is the state of things, not an event.
    public func swapEpisodes(in range: HistoryRange, now: Date) -> Int {
        let slice = window(range, now: now)
        var count = 0
        for i in slice.indices.dropFirst() where slice[i - 1].swapMB == 0 && slice[i].swapMB > 0 {
            count += 1
        }
        return count
    }

    // MARK: - Storage

    private static let magic: [UInt8] = Array("BH1".utf8)
    private static let recordSize = 7

    public func encoded() -> Data {
        var bytes: [UInt8] = Self.magic
        let n = UInt32(samples.count)
        bytes.append(contentsOf: [UInt8(n & 0xff), UInt8((n >> 8) & 0xff),
                                  UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)])
        bytes.reserveCapacity(bytes.count + samples.count * Self.recordSize)
        for s in samples {
            bytes.append(contentsOf: [UInt8(s.time & 0xff), UInt8((s.time >> 8) & 0xff),
                                      UInt8((s.time >> 16) & 0xff), UInt8((s.time >> 24) & 0xff)])
            bytes.append(s.pressure)
            bytes.append(contentsOf: [UInt8(s.swapMB & 0xff), UInt8((s.swapMB >> 8) & 0xff)])
        }
        return Data(bytes)
    }

    /// Nil for anything that is not a well-formed file of ours. A truncated or
    /// foreign file must never be half-read into the chart.
    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 7, Array(b[0..<3]) == Self.magic else { return nil }
        let n = Int(b[3]) | Int(b[4]) << 8 | Int(b[5]) << 16 | Int(b[6]) << 24
        guard n <= Self.capacity, b.count == 7 + n * Self.recordSize else { return nil }

        var out: [LongSample] = []
        out.reserveCapacity(n)
        var i = 7
        for _ in 0..<n {
            let t = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            let p = b[i + 4]
            let m = UInt16(b[i + 5]) | UInt16(b[i + 6]) << 8
            guard p <= 100 else { return nil }
            out.append(LongSample(time: t, pressure: p, swapMB: m))
            i += Self.recordSize
        }
        samples = out
    }
}

/// Where the history lives between launches.
public enum HistoryStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Boost/history.bin")
    }

    public static func load(from url: URL = defaultURL) -> LongHistory {
        guard let data = try? Data(contentsOf: url), let history = LongHistory(data: data) else {
            return LongHistory()
        }
        return history
    }

    public static func save(_ history: LongHistory, to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? history.encoded().write(to: url, options: .atomic)
    }
}
