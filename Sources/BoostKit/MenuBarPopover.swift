import SwiftUI
import AppKit

/// The menu bar popover: the surface people see every day.
///
/// A plain menu answers "how bad is it" with two lines of text. A popover can
/// answer it, show which way it is heading, name the apps responsible, and let
/// you act on them without opening a window, which is the moment this app is
/// actually for: the Mac already feels slow and hunting for a window is the
/// last thing you want to do.
public struct MenuBarContent: View {
    @ObservedObject var engine: Engine
    @ObservedObject var disk: DiskEngine

    public init(engine: Engine = .shared, disk: DiskEngine = .shared) {
        self.engine = engine
        self.disk = disk
    }

    public var body: some View {
        VStack(spacing: 14) {
            summary
            freeButton
            if engine.history.count >= 2 { graph }
            breakdown
            if !topItems.isEmpty { hogs }
            if !engine.pausedItems.isEmpty { paused }
            DiskStrip()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Pieces

    private var summary: some View {
        HStack(spacing: 14) {
            ZStack {
                RadialGauge(progress: engine.mem.pressure, tint: statusColor)
                    .frame(width: 58, height: 58)
                Text("\(Int(engine.mem.pressure * 100))")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .animation(.spring(response: 0.5, dampingFraction: 1.0), value: engine.mem.pressure)
            .accessibilityElement()
            .accessibilityLabel("Memory pressure")
            .accessibilityValue("\(Int(engine.mem.pressure * 100)) percent")

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(fmtBytes(engine.mem.used))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(fmtBytes(engine.mem.total))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Label(statusText, systemImage: "circle.fill")
                    .labelStyle(DotLabel())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 0)
        }
    }

    private var freeButton: some View {
        VStack(spacing: 6) {
            Button {
                engine.freeMemory()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "memorychip.fill")
                    Text(engine.busy ?? "Free Memory").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .controlSize(.large)
            .disabled(engine.busy != nil)

            if let report = engine.lastReport {
                Text(report)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: engine.lastReport)
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 5) {
            Sparkline(values: Array(engine.history.pressureSeries.suffix(90)), tint: statusColor)
                .frame(height: 40)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            if let trend = engine.history.trend() {
                Text(trend)
                    .font(.system(size: 11))
                    .foregroundStyle(engine.history.swapStarted ? statusColor : .secondary)
            }
        }
    }

    private var breakdown: some View {
        HStack(spacing: 8) {
            StatChip(title: "Cached", value: fmtBytes(engine.mem.cached),
                     hint: "Counts as available. macOS gives it back on demand.")
            StatChip(title: "Compressed", value: fmtBytes(engine.mem.compressed),
                     hint: "Squeezed in RAM, which is faster than swap.")
            StatChip(title: "Swap", value: engine.mem.swapUsed == 0 ? "None" : fmtBytes(engine.mem.swapUsed),
                     hint: "The number that matters. None means your Mac is coping.",
                     tint: engine.mem.swapUsed == 0 ? nil : statusColor)
        }
    }

    private var topItems: [Item] {
        engine.items
            .filter { !$0.isProtected && $0.category != .system && !$0.isPaused }
            .sorted { $0.rssBytes > $1.rssBytes }
            .prefix(5)
            .map { $0 }
    }

    private var hogs: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Using the most memory")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(topItems) { item in
                PopoverRow(engine: engine, item: item)
            }
        }
    }

    private var paused: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Resume All") { engine.resumeEverything() }
                    .controlSize(.small)
            }
            ForEach(engine.pausedItems) { item in
                PopoverRow(engine: engine, item: item)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Button("Open Boost") {
                NSApp.activate(ignoringOtherApps: true)
                openMainWindow()
            }
            Spacer()
            Button("Settings") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private var statusText: String {
        switch engine.mem.level {
        case .easy:     return "Plenty of headroom"
        case .moderate: return "Getting busy"
        case .tight:    return "Under pressure"
        }
    }

    private var statusColor: Color {
        switch engine.mem.level {
        case .easy:     return .green
        case .moderate: return .orange
        case .tight:    return .red
        }
    }

    /// The window is closed, not destroyed, when you click its red button, so
    /// bringing it back means finding it rather than making another.
    private func openMainWindow() {
        if let existing = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
            existing.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Row

/// One app in the popover. The size is shown until you point at the row, then
/// the two actions replace it, so the list stays quiet until you reach for it.
struct PopoverRow: View {
    @ObservedObject var engine: Engine
    let item: Item
    @StateObject private var hover = RowHover()

    var body: some View {
        HStack(spacing: 9) {
            if let icon = IconCache.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").frame(width: 22, height: 22).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let grown = engine.growthOf(item) {
                    Text("Up \(fmtBytes(grown)) and not coming back")
                        .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 6)

            if hover.on {
                if item.isPaused {
                    iconButton("play.fill", help: "Resume") { engine.resume(item) }
                } else {
                    iconButton("pause.fill", help: "Pause. Reversible.") { engine.pause(item) }
                    iconButton("xmark", help: "Quit") { engine.quit(item) }
                }
            } else {
                Text(fmtBytes(item.rssBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(hover.on ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 20)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Chip

struct StatChip: View {
    let title: String
    let value: String
    let hint: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .help(hint)
    }
}

// MARK: - Disk

/// Free space on the startup volume. "Important usage" is the figure Finder
/// shows: it counts purgeable space as available, which is what you can
/// actually use rather than the raw number.
enum StartupVolume {
    static func space() -> (free: UInt64, total: UInt64)? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]), let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return (UInt64(max(0, free)), UInt64(total))
    }
}

struct DiskStrip: View {
    var body: some View {
        if let space = StartupVolume.space() {
            let usedFraction = 1 - Double(space.free) / Double(space.total)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Disk", systemImage: "internaldrive")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(fmtBytes(space.free)) free")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Capsule().fill(Color.primary.opacity(0.1)).frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill((usedFraction > 0.9 ? Color.red : Color.brand).gradient)
                                .frame(width: geo.size.width * min(1, max(0, usedFraction)))
                        }
                    }
                    .frame(height: 5)
            }
        }
    }
}
