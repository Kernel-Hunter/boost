import Foundation

/// One reading, kept small because there will be a lot of them.
public struct MemorySample: Sendable, Equatable {
    public let at: Date
    public let used: UInt64
    public let cached: UInt64
    public let swap: UInt64
    public let pressure: Double
}

/// A rolling window of memory readings, and what can be concluded from them.
///
/// A single number tells you the Mac is busy. It cannot tell you whether it has
/// been busy for an hour or got that way in the last two minutes, and those
/// call for different responses — which is the whole reason for keeping any
/// history at all.
///
/// Bounded on purpose: an app that watches memory and grows without limit while
/// doing it would be its own best example of the problem.
public struct MemoryHistory: Sendable {

    /// Two hours at one sample every four seconds. Long enough to show a trend
    /// developing over a working session, short enough that the whole thing is
    /// well under a megabyte.
    public static let capacity = 1800

    private(set) var samples: [MemorySample] = []
    public var count: Int { samples.count }
    public var isEmpty: Bool { samples.isEmpty }
    public var latest: MemorySample? { samples.last }

    public init() { samples.reserveCapacity(Self.capacity) }

    public mutating func record(_ sample: MemorySample) {
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    public mutating func clear() { samples.removeAll(keepingCapacity: true) }

    // MARK: - Reading the shape

    /// Pressure as a 0...1 series, for drawing.
    public var pressureSeries: [Double] { samples.map(\.pressure) }

    public var peakUsed: UInt64 { samples.map(\.used).max() ?? 0 }
    public var lowestUsed: UInt64 { samples.map(\.used).min() ?? 0 }

    /// Change in bytes used across the window, negative when it fell.
    public var usedDelta: Int64 {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return Int64(bitPattern: last.used) - Int64(bitPattern: first.used)
    }

    /// Whether swap appeared during the window rather than being there all
    /// along. Swap arriving is the moment worth reacting to; swap that was
    /// already present when you opened the app is just the state of things.
    public var swapStarted: Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        return first.swap == 0 && last.swap > 0
    }

    /// A plain-language description of the direction of travel, or nil when
    /// there is not enough to say. Deliberately refuses to speak early: a
    /// trend drawn from four samples is a guess with a graph attached.
    public func trend(minimumSamples: Int = 15) -> String? {
        guard samples.count >= minimumSamples,
              let first = samples.first, let last = samples.last else { return nil }

        if swapStarted { return "Swap started during this session." }

        let delta = usedDelta
        let span = last.at.timeIntervalSince(first.at)
        guard span > 0 else { return nil }

        // Ignore anything under 200 MB: normal drift, and calling it a trend
        // trains people to ignore the line that matters.
        let threshold: Int64 = 200 * 1_048_576
        guard abs(delta) >= threshold else { return "Steady over the last \(minutes(span))." }

        let magnitude = fmtBytes(UInt64(abs(delta)))
        return delta > 0
            ? "Up \(magnitude) over the last \(minutes(span))."
            : "Down \(magnitude) over the last \(minutes(span))."
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "minute" }
        if m == 1 { return "minute" }
        if m < 60 { return "\(m) minutes" }
        let h = m / 60
        return h == 1 ? "hour" : "\(h) hours"
    }
}

// MARK: - Per-app growth

/// Tracks one app's memory over time, so the list can say which one is growing
/// rather than only which one is big. Big is usually fine — a browser is
/// supposed to be big. Growing steadily and never giving any back is the shape
/// of a leak, and that is the one worth pointing at.
public struct AppGrowth: Sendable {
    /// Keyed by the stable id, so a restarted app starts a fresh history rather
    /// than inheriting the old one's slope.
    private var series: [String: [UInt64]] = [:]

    /// Roughly ten minutes at the foreground refresh rate.
    public static let window = 300

    public init() {}

    public mutating func record(_ items: [(id: String, bytes: UInt64)]) {
        var next: [String: [UInt64]] = [:]
        next.reserveCapacity(items.count)
        for item in items {
            var history = series[item.id] ?? []
            history.append(item.bytes)
            if history.count > Self.window { history.removeFirst(history.count - Self.window) }
            next[item.id] = history
        }
        // Anything not in this sample has exited; drop it rather than keep a
        // series that can never be continued.
        series = next
    }

    /// How much this app's *floor* has risen, or nil when there is not enough
    /// history or it has not meaningfully grown.
    ///
    /// Compares the smallest reading in the first half of the window against
    /// the smallest in the second half. The obvious version — lowest ever
    /// against latest — flags any app that swings by more than the threshold,
    /// every time it happens to be sampled near the top of a swing. An app that
    /// rises and falls is working; one that never returns to where it started
    /// is holding on to something, and only the floor distinguishes them.
    public func growth(of id: String, minimumSamples: Int = 30,
                       threshold: UInt64 = 300 * 1_048_576) -> UInt64? {
        guard let history = series[id], history.count >= minimumSamples else { return nil }
        let mid = history.count / 2
        guard let earlyFloor = history.prefix(mid).min(),
              let lateFloor = history.suffix(from: mid).min(),
              lateFloor > earlyFloor else { return nil }
        let risen = lateFloor - earlyFloor
        return risen >= threshold ? risen : nil
    }

    public func samples(for id: String) -> Int { series[id]?.count ?? 0 }
}
