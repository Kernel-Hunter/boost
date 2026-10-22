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
    @StateObject private var copied = Flag()

    public init(engine: Engine = .shared, disk: DiskEngine = .shared) {
        self.engine = engine
        self.disk = disk
    }

    public var body: some View {
        VStack(spacing: 12) {
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
        .boostBackdrop(center: UnitPoint(x: 0.2, y: 0.0), strength: 0.12, opaque: false)
    }

    // MARK: - Pieces

    private var summary: some View {
        HStack(spacing: 14) {
            ZStack {
                RadialGauge(progress: engine.mem.pressure, tint: statusColor, lineWidth: 7)
                    .frame(width: 64, height: 64)
                Text("\(Int(engine.mem.pressure * 100))")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .boostAnimation(.spring(response: 0.5, dampingFraction: 1.0), value: engine.mem.pressure)
            .accessibilityElement()
            .accessibilityLabel("Memory pressure")
            .accessibilityValue("\(Int(engine.mem.pressure * 100)) percent")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(fmtBytes(engine.mem.used))
                        .font(.boostValue)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(fmtBytes(engine.mem.total))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .boostAnimation(.spring(response: 0.4, dampingFraction: 1.0), value: engine.mem.used)
                Label(statusText, systemImage: "circle.fill")
                    .labelStyle(DotLabel())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var freeButton: some View {
        VStack(spacing: 8) {
            Button {
                engine.freeMemory()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "memorychip.fill")
                        .boostPulse(active: engine.busy != nil)
                    Text(engine.busy ?? "Free Memory").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .boostProminentButton()
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
        .boostAnimation(.spring(duration: 0.3, bounce: 0), value: engine.lastReport)
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pressure")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(engine.mem.pressure * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .contentTransition(.numericText())
            }
            Sparkline(values: Array(engine.history.pressureSeries.suffix(90)), tint: statusColor,
                      showsMarker: true)
                .frame(height: 44)
                .padding(.horizontal, 6)
            if let trend = engine.history.trend() {
                Text(trend)
                    .font(.system(size: 11))
                    .foregroundStyle(engine.history.swapStarted ? statusColor : .secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .boostSurface()
    }

    private var breakdown: some View {
        BoostGlassContainer(spacing: 8) {
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
    }

    private var topItems: [Item] {
        // Real apps first: a command-line tool with no bundle, such as an npm
        // process, is not something you recognise or want to act on from here.
        engine.items
            .filter { !$0.isProtected && $0.category != .system && !$0.isPaused && $0.bundlePath != nil }
            .sorted { $0.rssBytes > $1.rssBytes }
            .prefix(5)
            .map { $0 }
    }

    private var hogs: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Using the most memory")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
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
                    .boostButton().controlSize(.small)
            }
            ForEach(engine.pausedItems) { item in
                PopoverRow(engine: engine, item: item)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        }
    }

    private var footer: some View {
        BoostGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                Button("Open Boost") {
                    NSApp.activate(ignoringOtherApps: true)
                    openMainWindow()
                }
                Spacer(minLength: 0)
                Button("Copy Report") { copyReport() }
                    .help("Copies memory figures and app names as plain text, for a bug report. Nothing is sent anywhere.")
                Button("Settings") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .boostButton()
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private var statusText: String { engine.mem.level.statusText }
    private var statusColor: Color { engine.mem.level.color }

    private func copyReport() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let report = MemoryReport.text(
            version: version, machine: MemoryReport.currentMachine(), mem: engine.mem,
            apps: topItems.map { MemoryReport.App(name: $0.name, bytes: $0.rssBytes) },
            pausedCount: engine.pausedItems.count, history: engine.longHistory)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied.on = true
        let flag = copied
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            flag.on = false
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
        HStack(spacing: 10) {
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
                BoostGlassContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        if item.isPaused {
                            iconButton("play.fill", help: "Resume") { engine.resume(item) }
                        } else {
                            iconButton("pause.fill", help: "Pause. Reversible.") { engine.pause(item) }
                            iconButton("xmark", help: "Quit") { engine.quit(item) }
                        }
                    }
                }
                .transition(.opacity)
            } else {
                Text(fmtBytes(item.rssBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(minHeight: 32)
        .background(Color.primary.opacity(hover.on ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .boostAnimation(.easeOut(duration: 0.12), value: hover.on)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .boostIconButtonLabel()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
                .contentTransition(.numericText())
                .foregroundStyle(tint ?? Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .boostGlass(cornerRadius: Radius.medium, tint: tint.map { $0.opacity(0.22) })
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
            VStack(alignment: .leading, spacing: 7) {
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
            .padding(.horizontal, 12).padding(.vertical, 10)
            .boostSurface()
        }
    }
}
