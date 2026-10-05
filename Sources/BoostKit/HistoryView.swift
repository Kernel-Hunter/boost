import SwiftUI

/// Remembered across launches, like the selected tab.
final class HistoryRangeSelection: ObservableObject {
    @Published var range: HistoryRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "historyRange") }
    }
    init() {
        let saved = UserDefaults.standard.string(forKey: "historyRange") ?? ""
        range = HistoryRange(rawValue: saved) ?? .day
    }
}

/// Memory pressure over the last two hours, a day or a week, with the worst
/// moment named and every stretch where the Mac started swapping marked.
struct HistoryCard: View {
    let history: LongHistory
    @StateObject private var selection = HistoryRangeSelection()

    var body: some View {
        let now = Date()
        let range = selection.range
        let points = history.points(for: range, now: now)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Range", selection: $selection.range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            if points.count < 3 {
                Text("Collecting readings. Boost records one a minute and keeps a week, so this fills in as you use your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else {
                HistoryChart(points: points, range: range, now: now)
                    .frame(height: 64)
                HStack {
                    Text(range.axisLabel)
                    Spacer()
                    Text(summary(range: range, now: now))
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .padding(.horizontal, 18).padding(.bottom, 8)
    }

    private func summary(range: HistoryRange, now: Date) -> String {
        var parts: [String] = []
        if let peak = history.peak(in: range, now: now) {
            let when = peak.at.formatted(date: range == .week ? .abbreviated : .omitted, time: .shortened)
            parts.append("Peak \(Int(peak.pressure * 100))% at \(when)")
        }
        if let average = history.average(in: range, now: now) {
            parts.append("Average \(Int(average * 100))%")
        }
        let swaps = history.swapEpisodes(in: range, now: now)
        if swaps > 0 { parts.append("Swap appeared \(swaps) \(swaps == 1 ? "time" : "times")") }
        return parts.joined(separator: "  ·  ")
    }
}

/// Hand-drawn like the sparkline: one series, a few guide lines, no framework.
/// Time runs left to right across the whole window, so a Mac that has only
/// been watched for an hour shows an hour on the right and nothing on the left
/// instead of stretching it to look like a day.
struct HistoryChart: View {
    let points: [ChartPoint]
    let range: HistoryRange
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let start = now.addingTimeInterval(-range.seconds)
            let coords = points.map { p in
                CGPoint(x: CGFloat(p.date.timeIntervalSince(start) / range.seconds) * w,
                        y: h - CGFloat(max(0, min(1, p.pressure))) * h)
            }

            ZStack(alignment: .topLeading) {
                ForEach([0.75, 0.9], id: \.self) { level in
                    Path { p in
                        let y = h - CGFloat(level) * h
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }

                if let first = coords.first, let last = coords.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: h))
                        for c in coords { p.addLine(to: c) }
                        p.addLine(to: CGPoint(x: last.x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Color.brand.opacity(0.32), Color.brand.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { p in p.addLines(coords) }
                        .stroke(Color.brand.opacity(0.9),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }

                ForEach(Array(zip(points.indices, points)), id: \.0) { i, p in
                    if p.swapped {
                        Capsule().fill(Color.orange)
                            .frame(width: max(2, w / CGFloat(max(points.count, 1))), height: 3)
                            .position(x: coords[i].x, y: h - 1.5)
                    }
                }
            }
        }
        .accessibilityLabel("Memory pressure history")
    }
}
