import SwiftUI
import AppKit

// MARK: - Brand

extension Color {
    /// Boost's own accent, not the generic system blue every other utility
    /// defaults to. A controlled teal — reads as performance/clarity rather
    /// than borrowing whatever the OS's accent color happens to be, so the
    /// app has a visual identity of its own regardless of what someone set
    /// in System Settings. Used for anything that should read as "this is
    /// Boost speaking": primary actions, the gauge, the sparkline, the
    /// sidebar's selected state.
    static let brand = Color(red: 0.10, green: 0.78, blue: 0.64)
}

// MARK: - Icons

/// Main-actor confined rather than `nonisolated(unsafe)`: it is a plain mutable
/// dictionary with no locking, and every caller is a view, which is already on
/// the main actor. Stating that is free and lets the compiler hold us to it.
@MainActor
enum IconCache {
    private static var store: [String: NSImage] = [:]
    static func icon(for item: Item) -> NSImage? {
        let key = item.bundlePath ?? item.id
        if let hit = store[key] { return hit }
        var image: NSImage?
        if let pid = item.runningAppPID, let app = NSRunningApplication(processIdentifier: pid) {
            image = app.icon
        }
        if image == nil, let path = item.bundlePath, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        if let image { store[key] = image }
        return image
    }
}

// MARK: - Root

public enum Tab: String, CaseIterable, Identifiable {
    case memory, disk
    public var id: String { rawValue }
    var title: String { self == .memory ? "Memory" : "Disk" }
    var symbol: String { self == .memory ? "memorychip" : "internaldrive" }
}

/// Which tab is showing, remembered across launches — reopening the app on
/// the tab you left it on is the behaviour people expect and notice when it
/// is missing.
///
/// A tiny ObservableObject rather than @State because @State is macro-backed
/// in this SDK and SwiftUIMacros ships with Xcode, not with Command Line
/// Tools — see CONTRIBUTING. Same reason as RowHover below.
final class TabSelection: ObservableObject {
    @Published var tab: Tab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab") }
    }
    init() {
        let saved = UserDefaults.standard.string(forKey: "selectedTab") ?? ""
        tab = Tab(rawValue: saved) ?? .memory
    }
}

public struct ContentView: View {
    @ObservedObject private var engine = Engine.shared
    @ObservedObject private var disk = DiskEngine.shared
    @StateObject private var tabs = TabSelection()
    @StateObject private var firstRun = FirstRun()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(tab: $tabs.tab, engine: engine)
            Divider().opacity(0.5)
            Group {
                switch tabs.tab {
                case .memory: memoryTab
                case .disk:   DiskView(engine: disk)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let report = disk.report, tabs.tab == .disk {
                Toast(text: report).padding(.bottom, 76)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: disk.report)
    }

    private var memoryTab: some View {
        VStack(spacing: 0) {
            MemoryHeader(engine: engine)
            Divider().opacity(0.5)
            FilterBar(engine: engine)
            Divider().opacity(0.5)
            if engine.needsAccessibility { AccessibilityBanner(engine: engine) }
            if !firstRun.dismissed { FirstRunCard(firstRun: firstRun) }
            processList
            FooterBar(engine: engine)
        }
        .overlay(alignment: .bottom) {
            if let report = engine.lastReport { Toast(text: report).padding(.bottom, 76) }
        }
        .animation(.spring(duration: 0.35, bounce: 0), value: engine.lastReport)
        .animation(.spring(duration: 0.3, bounce: 0), value: engine.pausedItems.count)
        .confirmationDialog("Force quit without saving?", isPresented: $engine.confirmForce) {
            Button("Force Quit", role: .destructive) { engine.quitSelected(force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These apps will be killed immediately. Anything unsaved is lost.")
        }
    }

    private var processList: some View {
        List {
            ForEach(Category.allCases) { category in
                let rows = engine.items(in: category)
                if !rows.isEmpty {
                    Section {
                        if engine.isExpanded(category) {
                            ForEach(rows) { item in
                                ItemRow(engine: engine, item: item)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    } header: {
                        SectionHeader(engine: engine, category: category, items: rows)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            if engine.visibleItems.isEmpty {
                emptyState.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    /// An empty list here nearly always means a filter is on, not that nothing
    /// is running — so it says which, and offers the way out.
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: engine.search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)

            if !engine.search.isEmpty {
                Text("No matches for “\(engine.search)”")
                    .foregroundStyle(.secondary)
                Button("Clear the filter") { engine.search = "" }
                    .controlSize(.small)
            } else if !engine.showSystem {
                Text("Nothing of yours is running.")
                    .foregroundStyle(.secondary)
                Text("macOS's own processes are hidden. Turn on **Show system processes** to see them.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            } else {
                Text("Nothing running to show.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 70)
    }
}

// MARK: - Sidebar

/// A real sidebar rather than a thin top strip: this is the one navigation
/// decision that most changes how the app reads at a glance — a sidebar
/// reads as a considered app with a place for things to grow, the way
/// Mail, Notes, and most of the utilities in Boost's own category (iStat
/// Menus, DaisyDisk) are laid out. It carries a persistent, always-visible
/// pressure readout at its foot, so the number that matters most is never
/// lost just because you switched to the Disk tab.
struct Sidebar: View {
    @Binding var tab: Tab
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.brand)
                Text("Boost")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)

            ForEach(Tab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                        Text(t.title).font(.system(size: 12.5, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == t ? Color.white : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        if tab == t {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.brand.gradient)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .help(t == .memory ? "Running apps and memory" : "Reclaimable disk space")
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(tab == t ? [.isButton, .isSelected] : .isButton)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Memory").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(engine.mem.pressure * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Capsule().fill(Color.primary.opacity(0.1)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(Color.brand.gradient)
                                .frame(width: geo.size.width * min(1, max(0, engine.mem.pressure)))
                        }
                    }
                    .frame(height: 4)
            }
            .padding(11)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
            .animation(.spring(response: 0.4, dampingFraction: 1.0), value: engine.mem.pressure)
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: tab)
    }
}

// MARK: - Header

struct MemoryHeader: View {
    @ObservedObject var engine: Engine

    private var statusText: String {
        switch engine.mem.level {
        case .easy:     return "Plenty of headroom"
        case .moderate: return "Getting busy"
        case .tight:    return "Under pressure"
        }
    }
    private var statusColor: Color {
        switch engine.mem.level {
        case .easy: return .green
        case .moderate: return .orange
        case .tight: return .red
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            ZStack {
                RadialGauge(progress: engine.mem.pressure, tint: statusColor)
                    .frame(width: 92, height: 92)
                VStack(spacing: 0) {
                    Text("\(Int(engine.mem.pressure * 100))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 1.0), value: engine.mem.pressure)
            .accessibilityElement()
            .accessibilityLabel("Memory pressure")
            .accessibilityValue("\(Int(engine.mem.pressure * 100)) percent")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fmtBytes(engine.mem.used))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .kerning(-0.6)
                        .contentTransition(.numericText())
                    Text("of \(fmtBytes(engine.mem.total))")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .animation(.spring(response: 0.4, dampingFraction: 1.0), value: engine.mem.used)

                HStack(spacing: 14) {
                    Label(statusText, systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                        .labelStyle(DotLabel())
                    Text("\(fmtBytes(engine.mem.cached)) cached")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(engine.mem.swapUsed == 0
                         ? "no swap"
                         : "\(fmtBytes(engine.mem.swapUsed)) swap")
                        .font(.caption)
                        .foregroundStyle(engine.mem.swapUsed == 0 ? .secondary : statusColor)
                }

                if engine.history.count >= 2 {
                    HStack(spacing: 10) {
                        Sparkline(values: engine.history.pressureSeries, tint: statusColor)
                            .frame(width: 120, height: 22)
                        if let trend = engine.history.trend() {
                            Text(trend)
                                .font(.caption)
                                .foregroundStyle(engine.history.swapStarted ? statusColor : .secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    engine.freeMemory()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "memorychip.fill")
                        Text(engine.busy ?? "Free Memory").fontWeight(.semibold)
                    }
                    .frame(minWidth: 168)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brand)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(engine.busy != nil)
                .accessibilityLabel("Free memory without closing anything")
                .help("Reclaims idle memory without closing apps or asking for a password. "
                    + "Stops on its own if your Mac starts paging to disk.")

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.brand.gradient, in: Circle())
                        Text("How Free Memory actually works")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text("It briefly asks macOS for memory so the system releases idle pages, then gives that request back. Apps stay open, swap is watched, and it stops before paging becomes the cost.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Label("No app closing", systemImage: "checkmark.circle.fill")
                        // This claim is only true while the opt-in purge
                        // setting is off — that's the one thing Free Memory
                        // does that asks for a password. Saying "no admin
                        // password" unconditionally while it was about to
                        // ask for one is exactly the kind of invented
                        // reassurance this app exists to not do.
                        if engine.purgeOnBoost {
                            Label("Also purges disk cache (asks for your password)", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Label("No admin password", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                }
                .padding(12)
                .frame(width: 264, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(.regularMaterial)
    }
}

/// A ring instead of a bar for the header's headline figure — the one
/// piece of this redesign meant to read as a dashboard at a glance rather
/// than a labelled stat. `.round` line caps and a gradient stroke keep it
/// from looking like a stock progress indicator.
struct RadialGauge: View {
    let progress: Double   // 0...1
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.system(size: 12))
                TextField("Filter", text: $engine.search)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                if !engine.search.isEmpty {
                    Button { engine.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            Spacer()

            if !engine.pausedItems.isEmpty {
                Label("\(engine.pausedItems.count) paused", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }

            if engine.autoQuitOnClose && !engine.needsAccessibility {
                Label("Close = quit", systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.14), in: Capsule())
                    .help("Apps quit when you close their last window")
            }

            SortControl(engine: engine)

            Toggle("Show system processes", isOn: $engine.showSystem)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.caption)
                .help("macOS internals. Protected ones can be seen but never closed or paused.")
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(.bar)
    }
}

/// Name / Memory / CPU, with a direction flip. There was no way to change
/// how the list was ordered before this — buildItems() fixed it at
/// size-descending and nothing in the UI could ask for anything else.
struct SortControl: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(SortOption.allCases) { option in
                    Button {
                        engine.sortOption = option
                    } label: {
                        if engine.sortOption == option { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            } label: {
                Label(engine.sortOption.title, systemImage: engine.sortOption.symbol)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort the list by")

            Button {
                engine.sortAscending.toggle()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(engine.sortAscending ? 0 : 180))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(4)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 1.0), value: engine.sortAscending)
            .help(engine.sortAscending ? "Ascending — click for descending" : "Descending — click for ascending")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Section header

struct SectionHeader: View {
    @ObservedObject var engine: Engine
    let category: Category
    let items: [Item]

    private var actionable: [Item] { items.filter { !$0.isProtected && !engine.isKept($0) } }
    private var allOn: Bool { !actionable.isEmpty && actionable.allSatisfy { engine.isSelected($0) } }
    private var totalBytes: UInt64 { items.reduce(0) { $0 + $1.rssBytes } }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { allOn },
                set: { engine.setSelection($0, for: category) }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .disabled(actionable.isEmpty)

            Button { engine.toggleExpanded(category) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(engine.isExpanded(category) ? 90 : 0))

                    Image(systemName: category.symbol)
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.title).font(.system(size: 12, weight: .semibold))
                        Text(category.blurb).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text("\(items.count) · \(fmtBytes(totalBytes))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .animation(.spring(duration: 0.28, bounce: 0), value: engine.isExpanded(category))
        .padding(.horizontal, 22).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

// MARK: - Row

/// Scoped to a single row so hovering repaints that row alone.
final class RowHover: ObservableObject { @Published var on = false }

struct ItemRow: View {
    @ObservedObject var engine: Engine
    let item: Item
    @StateObject private var hover = RowHover()

    private var locked: Bool { item.isProtected }
    private var kept: Bool { engine.isKept(item) }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { engine.isSelected(item) },
                set: { _ in engine.toggle(item) }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .disabled(locked || kept)
            .accessibilityLabel("Select \(item.name)")

            iconView

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if item.isPaused { badge("Paused", .orange) }
                    if locked { badge("Protected", .secondary) }
                    else if kept { badge("Kept", .blue) }
                    // Big is not a problem — a browser is supposed to be big.
                    // A floor that keeps rising is, and it is invisible in a
                    // single reading.
                    if let grown = engine.growthOf(item) {
                        badge("+\(fmtBytes(grown))", .purple)
                            .help("Its lowest memory use has risen by \(fmtBytes(grown)) "
                                + "since Boost started watching — it is not giving back "
                                + "what it takes.")
                    }
                }
                Text(item.processCount == 1 ? "1 process" : "\(item.processCount) processes")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if hover.on { rowActions.transition(.opacity) }

            Text(item.rssKnown ? fmtBytes(item.rssBytes) : "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(item.rssKnown ? .secondary : .tertiary)
                .help(item.rssKnown ? "" : "Owned by root, so macOS will not report its memory to us")
                .frame(width: 74, alignment: .trailing)

            cpuMeter
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(item.isPaused ? 0.62 : 1)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hover.on ? Color.primary.opacity(0.05) : Color.primary.opacity(0.028))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hover.on ? Color.brand.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
        }
        .padding(.horizontal, 22).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: hover.on)
        .contextMenu {
            Button(kept ? "Stop protecting" : "Never close this") { engine.toggleKeep(item) }
                .disabled(locked)
            Divider()
            Button(item.isPaused ? "Resume" : "Pause") {
                item.isPaused ? engine.resume(item) : engine.pause(item)
            }.disabled(locked)
            Button("Close") { engine.quit(item) }.disabled(locked)
            if let path = item.bundlePath {
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
        }
    }

    @ViewBuilder private var iconView: some View {
        if let icon = IconCache.icon(for: item) {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            // No real app icon to show — a category symbol on its own reads
            // as an empty slot next to rows that have real icons. A soft
            // rounded container gives it the same visual weight instead.
            Image(systemName: item.category.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var rowActions: some View {
        HStack(spacing: 3) {
            Button {
                item.isPaused ? engine.resume(item) : engine.pause(item)
                engine.refresh()
            } label: {
                Image(systemName: item.isPaused ? "play.fill" : "pause.fill").font(.system(size: 10))
            }
            .buttonStyle(.borderless).disabled(locked)
            .help(item.isPaused ? "Resume" : "Pause: freezes it at zero CPU and keeps its state")
            .accessibilityLabel(item.isPaused ? "Resume \(item.name)" : "Pause \(item.name)")

            Button { engine.quit(item); engine.refresh() } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.borderless).disabled(locked)
            .help("Close")
            .accessibilityLabel("Close \(item.name)")

            Button { engine.toggleKeep(item) } label: {
                Image(systemName: kept ? "pin.fill" : "pin").font(.system(size: 10))
            }
            .buttonStyle(.borderless).disabled(locked)
            .help(kept ? "Stop protecting" : "Never close this")
            .accessibilityLabel(kept ? "Stop protecting \(item.name)" : "Never close \(item.name)")
        }
        .foregroundStyle(.secondary)
    }

    private var cpuMeter: some View {
        HStack(spacing: 5) {
            Capsule().fill(Color.primary.opacity(0.08))
                .frame(width: 34, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(item.cpu > 40 ? Color.orange : Color.secondary.opacity(0.65))
                        .frame(width: 34 * min(item.cpu, 100) / 100)
                }
            // Below 10%, an integer percentage reads as "0%" for almost
            // everything on a Mac that's actually idle — real activity in
            // the 0.1–9% range is exactly what this column exists to show,
            // and rounding it away made the whole column look broken.
            Text(fmtCPU(item.cpu))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Footer

struct FooterBar: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(engine.selectedItems.count) selected · \(fmtBytes(engine.selectedBytes))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text("Pausing is reversible. Closing is not.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Spacer()

            if !engine.pausedItems.isEmpty {
                Button {
                    engine.resumeEverything()
                } label: {
                    Label("Resume All (\(engine.pausedItems.count))", systemImage: "play.fill")
                }
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .tint(.orange)
            }

            Button {
                engine.pauseSelected()
            } label: { Label("Pause", systemImage: "pause.fill") }
                .controlSize(.large)
                .disabled(engine.selectedItems.isEmpty)
                .help("Freeze at zero CPU without losing anything")

            Button {
                engine.quitSelected()
            } label: { Label("Close", systemImage: "xmark") }
                .controlSize(.large)
                // Closing and Free Memory share one `busy` flag on Engine, so
                // starting Close while a Free Memory run is still in flight
                // (or the reverse) lets one overwrite the other's status text
                // and clear it early. The menu bar's Close button already
                // guards this; this one didn't.
                .disabled(engine.selectedItems.isEmpty || engine.busy != nil)

            Menu {
                Toggle("Close button quits the app", isOn: $engine.autoQuitOnClose)
                Toggle("Global shortcut (⌥⌘B)", isOn: $engine.globalHotkey)
                    .help("Opens Boost and closes what is ticked, from any app.")
                Divider()
                RuleMenuItems()
                Divider()
                Toggle("Also purge disk cache", isOn: $engine.purgeOnBoost)
                    .help("Asks for your admin password and drops macOS's disk "
                        + "cache. Makes free memory look higher and the Mac "
                        + "briefly slower. Rarely worth it, so it is off by default.")
                Toggle("Resume everything when Boost quits", isOn: $engine.resumeOnQuit)
                Divider()
                Button("Force Quit Selected…") { engine.confirmForce = true }
                    .disabled(engine.selectedItems.isEmpty)
                Button("Refresh Now") { engine.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

/// Shown only while "close = quit" is on but Accessibility access is missing,
/// because without it the watcher cannot see any app's windows.
struct AccessibilityBanner: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Boost needs Accessibility access")
                    .font(.system(size: 12, weight: .semibold))
                Text("It's how Boost sees whether an app still has windows open. Nothing else uses it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { WindowWatcher.openAccessibilitySettings() }
                .controlSize(.small)
            Button("Turn Off") { engine.autoQuitOnClose = false }
                .controlSize(.small)
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(.thickMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - History

/// Pressure over the last while, drawn as a filled line.
///
/// Hand-rolled with Path rather than Swift Charts: this is one series with no
/// axes, no legend and no interaction, which is a few lines here and a
/// framework dependency there. It also keeps the app building with Command
/// Line Tools alone, which a macro-using dependency would end.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Needs two points to be a line. One reading is not a shape.
            if values.count >= 2 {
                let step = w / CGFloat(values.count - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step, y: h - (CGFloat(max(0, min(1, v))) * h))
                }

                // Fill first, line over it, so the stroke stays crisp.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLines(points)
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))

                Path { p in p.addLines(points) }
                    .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.5,
                                                                   lineCap: .round,
                                                                   lineJoin: .round))
            }
        }
        .accessibilityHidden(true)      // the trend sentence beside it says this in words
    }
}


// MARK: - Rules

/// The automation settings, in the overflow menu beside the other switches.
struct RuleMenuItems: View {
    @ObservedObject private var rules = Rules.shared

    var body: some View {
        Toggle("Warn me when swap climbs", isOn: Binding(
            get: { rules.enabled },
            set: { on in
                rules.enabled = on
                // Asking for notification permission belongs to the moment you
                // switch this on, not to app launch and not to a property setter.
                if on { rules.requestPermission() }
            }
        ))
        .help("Swap is the number that means your Mac has actually run out, "
            + "rather than merely being busy.")

        if rules.enabled {
            Picker("Past", selection: $rules.swapThresholdGB) {
                Text("1 GB of swap").tag(1.0)
                Text("2 GB of swap").tag(2.0)
                Text("4 GB of swap").tag(4.0)
            }
            Picker("Then", selection: $rules.action) {
                ForEach(RuleAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }
}

// MARK: - First run

/// Shown once, above the list, the first time Boost is opened.
///
/// Not a modal tour. The only thing a new user genuinely needs before touching
/// anything is that one of the two buttons is reversible and the other is not,
/// and that the big number is usually fine — everything else is discoverable by
/// reading the window. A wall of slides in front of a utility is a tax on
/// people who already understood it from the first screen.
final class FirstRun: ObservableObject {
    @Published var dismissed: Bool {
        didSet { UserDefaults.standard.set(dismissed, forKey: "firstRunDismissed") }
    }
    init() { dismissed = UserDefaults.standard.bool(forKey: "firstRunDismissed") }
}

struct FirstRunCard: View {
    @ObservedObject var firstRun: FirstRun

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.wave")
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("Two things worth knowing")
                    .font(.system(size: 12, weight: .semibold))

                // Markdown, and therefore written as single literals. SwiftUI
                // only parses it from a literal: build the same string with `+`
                // and it becomes a runtime String, which renders the asterisks
                // instead of the bold. That mistake is invisible in code review
                // and obvious in a screenshot.
                VStack(alignment: .leading, spacing: 3) {
                    Text("**Free Memory** is the main action. It asks macOS to reclaim idle pages, then gives the request back. It does not close apps.")
                    Text("**Pause** and **Close** are optional process tools. Pause is reversible; Close quits apps. **Swap** is the number that tells you when memory pressure is real.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Got it") {
                withAnimation(.spring(duration: 0.3, bounce: 0)) { firstRun.dismissed = true }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(Color.brand.opacity(0.07))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
