import Foundation

/// Plain text a person can paste into a bug report, a forum thread or a message
/// to someone helping with a slow Mac. It holds the figures that answer the
/// first questions anyone asks: how much memory, how much swap, which apps.
///
/// It lists app names and sizes and nothing else: no file paths, no user name,
/// no process arguments. Nothing leaves the Mac unless the person pastes it.
enum MemoryReport {

    struct App: Equatable {
        let name: String
        let bytes: UInt64
    }

    struct Machine: Equatable {
        var os: String
        var model: String
        var chip: String
    }

    static func text(version: String, machine: Machine, mem: MemStats, apps: [App],
                     pausedCount: Int, history: LongHistory?, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("Boost \(version) memory report")
        lines.append([machine.os, machine.model, machine.chip, fmtBytes(mem.total)]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        lines.append("")
        lines.append("Pressure \(Int(mem.pressure * 100))% (\(label(for: mem.level)))")
        lines.append("In use \(fmtBytes(mem.used)) of \(fmtBytes(mem.total))")
        lines.append("Cached \(fmtBytes(mem.cached)), compressed \(fmtBytes(mem.compressed)), "
            + "swap \(mem.swapUsed == 0 ? "none" : fmtBytes(mem.swapUsed))")
        if pausedCount > 0 { lines.append("Paused apps: \(pausedCount)") }

        if !apps.isEmpty {
            lines.append("")
            lines.append("Biggest apps (system and command line processes left out)")
            for app in apps { lines.append("  \(app.name) \(fmtBytes(app.bytes))") }
        }

        if let history, let summary = historySummary(history, now: now) {
            lines.append("")
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    static func label(for level: MemStats.Level) -> String {
        switch level {
        case .easy:     return "plenty of headroom"
        case .moderate: return "getting busy"
        case .tight:    return "under pressure"
        }
    }

    /// Nil until there is enough to say something true about the last day.
    static func historySummary(_ history: LongHistory, now: Date) -> String? {
        guard history.points(for: .day, now: now).count >= 3,
              let peak = history.peak(in: .day, now: now),
              let average = history.average(in: .day, now: now) else { return nil }
        var parts = ["Last 24 hours: peak \(Int(peak.pressure * 100))% at "
                     + peak.at.formatted(date: .omitted, time: .shortened),
                     "average \(Int(average * 100))%"]
        let swaps = history.swapEpisodes(in: .day, now: now)
        parts.append(swaps == 0 ? "no swap" : "swap appeared \(swaps) \(swaps == 1 ? "time" : "times")")
        return parts.joined(separator: ", ")
    }

    /// The machine as the report names it. Read from sysctl and ProcessInfo, so
    /// it needs no permission.
    static func currentMachine() -> Machine {
        Machine(os: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
                    .replacingOccurrences(of: "Version ", with: ""),
                model: sysctlString("hw.model"),
                chip: sysctlString("machdep.cpu.brand_string"))
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
