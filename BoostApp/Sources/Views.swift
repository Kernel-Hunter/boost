import SwiftUI
import AppKit

// MARK: - Icons

enum IconCache {
    nonisolated(unsafe) private static var store: [String: NSImage] = [:]
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

struct ContentView: View {
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        VStack(spacing: 0) {
            MemoryHeader(engine: engine)
            Divider().opacity(0.5)
            FilterBar(engine: engine)
            Divider().opacity(0.5)
            if engine.needsAccessibility { AccessibilityBanner(engine: engine) }
            processList
            FooterBar(engine: engine)
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
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
                                    .listRowSeparator(.visible)
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(engine.search.isEmpty ? "Nothing running to show." : "No matches for “\(engine.search)”.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 70)
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
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fmtBytes(engine.mem.used))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .kerning(-0.6)
                    Text("in use of \(fmtBytes(engine.mem.total))")
                        .font(.title3).foregroundStyle(.secondary)
                }

                MemoryBar(mem: engine.mem)
                    .frame(height: 9)
                    .frame(maxWidth: 460)

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
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    engine.quitSelected()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.fill")
                        Text(engine.busy ?? "Boost").fontWeight(.semibold)
                    }
                    .frame(minWidth: 116)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(engine.selectedItems.isEmpty || engine.busy != nil)
                .help("Close everything ticked below, then drop the disk cache")

                Text(engine.selectedItems.isEmpty
                     ? "Nothing ticked"
                     : "Closes \(engine.selectedItems.count) · frees ~\(fmtBytes(engine.selectedBytes))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(.regularMaterial)
    }
}

/// Used / cached / free as one continuous bar — cached is deliberately shown as
/// its own colour because it is *available*, not wasted.
struct MemoryBar: View {
    let mem: MemStats

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(Double(mem.total), 1)
            let usedW = w * Double(mem.used) / total
            let cacheW = w * Double(mem.cached) / total

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    Rectangle().fill(
                        LinearGradient(colors: [.accentColor, .accentColor.opacity(0.75)],
                                       startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, usedW))
                    Rectangle().fill(Color.accentColor.opacity(0.22))
                        .frame(width: max(0, cacheW))
                }
                .clipShape(Capsule())
            }
        }
        .animation(.easeOut(duration: 0.25), value: mem.used)
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

            Toggle("Show system processes", isOn: $engine.showSystem)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.caption)
                .help("macOS internals. Protected ones can be seen but never closed or paused.")
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(.bar)
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

            iconView

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if item.isPaused { badge("Paused", .orange) }
                    if locked { badge("Protected", .secondary) }
                    else if kept { badge("Kept", .blue) }
                }
                Text(item.processCount == 1 ? "1 process" : "\(item.processCount) processes")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if hover.on { rowActions.transition(.opacity) }

            Text(item.rssKnown ? fmtBytes(item.rssBytes) : "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(item.rssKnown ? .secondary : .tertiary)
                .help(item.rssKnown ? "" : "Owned by root — macOS won't report its memory to us")
                .frame(width: 74, alignment: .trailing)

            cpuMeter
        }
        .padding(.horizontal, 22).padding(.vertical, 7)
        .opacity(item.isPaused ? 0.62 : 1)
        .background(hover.on ? Color.primary.opacity(0.045) : .clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
        .contextMenu {
            Button(kept ? "Stop protecting" : "Never close this") { engine.toggleKeep(item) }
                .disabled(locked)
            Divider()
            Button(item.isPaused ? "Resume" : "Pause") {
                item.isPaused ? engine.resume(item) : engine.pause(item)
            }.disabled(locked)
            Button("Close") { engine.quit(item) }.disabled(locked)
        }
    }

    @ViewBuilder private var iconView: some View {
        if let icon = IconCache.icon(for: item) {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: item.category.symbol)
                .foregroundStyle(.tertiary).frame(width: 22, height: 22)
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
            .help(item.isPaused ? "Resume" : "Pause — freezes it at zero CPU, keeps its state")

            Button { engine.quit(item); engine.refresh() } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.borderless).disabled(locked)
            .help("Close")

            Button { engine.toggleKeep(item) } label: {
                Image(systemName: kept ? "pin.fill" : "pin").font(.system(size: 10))
            }
            .buttonStyle(.borderless).disabled(locked)
            .help(kept ? "Stop protecting" : "Never close this")
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
            Text("\(Int(item.cpu))%")
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
                .disabled(engine.selectedItems.isEmpty)

            Menu {
                Toggle("Close button quits the app", isOn: $engine.autoQuitOnClose)
                Divider()
                Toggle("Purge disk cache after closing", isOn: $engine.purgeOnBoost)
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
