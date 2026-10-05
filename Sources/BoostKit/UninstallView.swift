import SwiftUI
import AppKit

// MARK: - Helpers

/// Main-actor confined for the same reason as `IconCache` in Views.swift.
@MainActor
private enum AppIconCache {
    private static var store: [String: NSImage] = [:]
    static func icon(forPath path: String) -> NSImage {
        if let hit = store[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        store[path] = image
        return image
    }
}

@MainActor
private enum UninstallText {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func lastUsed(_ date: Date?) -> String {
        guard let date else { return "Last used unknown" }
        return "Used " + relative.localizedString(for: date, relativeTo: Date())
    }

    static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Root

struct UninstallView: View {
    @ObservedObject private var engine = UninstallEngine.shared

    var body: some View {
        HStack(spacing: 0) {
            AppListPane(engine: engine)
                .frame(width: 292)
            Divider().opacity(0.5)
            DetailPane(engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [Color.brand.opacity(0.08), Color.clear],
                    center: UnitPoint(x: 0.12, y: 0.1),
                    startRadius: 0, endRadius: 420
                )
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if let notice = engine.notice { Toast(text: notice).padding(.bottom, 56) }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: engine.notice)
        .confirmationDialog(
            "Move \(engine.chosenCount) \(engine.chosenCount == 1 ? "item" : "items") to the Trash?",
            isPresented: $engine.confirming
        ) {
            Button("Move to Trash") { engine.trash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(fmtBytes(engine.chosenBytes)) in total. Nothing is deleted. "
                 + "You can put it all back from the Trash, or press Undo straight after.")
        }
        .onAppear { if engine.apps.isEmpty && !engine.loading { engine.load() } }
    }
}

// MARK: - Left: the list of apps

private struct AppListPane: View {
    @ObservedObject var engine: UninstallEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .background(.bar.opacity(0.5))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("\(engine.visibleApps.count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    engine.load()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(engine.loading)
                .help("Look for apps again")
                .accessibilityLabel("Reload app list")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("Search apps", text: $engine.search)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                if !engine.search.isEmpty {
                    Button {
                        engine.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Picker("Sort by", selection: $engine.sort) {
                    ForEach(AppSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small)
                .fixedSize()
                .help("Sort the list by")

                Button {
                    engine.ascending.toggle()
                } label: {
                    Image(systemName: engine.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(engine.ascending ? "Ascending. Click for descending." : "Descending. Click for ascending.")
                .accessibilityLabel(engine.ascending ? "Ascending" : "Descending")
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)
    }

    @ViewBuilder private var list: some View {
        if engine.loading && engine.apps.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Finding apps…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.visibleApps.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: engine.search.isEmpty ? "square.dashed" : "magnifyingglass")
                    .font(.system(size: 24)).foregroundStyle(.tertiary)
                Text(engine.search.isEmpty ? "No apps found." : "No match for “\(engine.search)”")
                    .foregroundStyle(.secondary)
                if !engine.search.isEmpty {
                    Button("Clear the search") { engine.search = "" }.controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(engine.visibleApps) { app in
                    AppRow(engine: engine, app: app)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        }
    }
}

private struct AppRow: View {
    @ObservedObject var engine: UninstallEngine
    let app: InstalledApp
    @StateObject private var hover = RowHover()

    private var isSelected: Bool { engine.selected?.id == app.id }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconCache.icon(forPath: app.url.path))
                .resizable().frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(UninstallText.lastUsed(app.lastUsed))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(app.bytes.map(fmtBytes) ?? "…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.brand.opacity(0.16)
                      : hover.on ? Color.primary.opacity(0.05) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Color.brand.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .padding(.horizontal, 8).padding(.vertical, 1.5)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { engine.select(app) }
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: hover.on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Right: detail

private struct DetailPane: View {
    @ObservedObject var engine: UninstallEngine

    var body: some View {
        Group {
            if let result = engine.result {
                ResultCard(engine: engine, result: result)
            } else if let app = engine.selected {
                SelectedApp(engine: engine, app: app)
            } else {
                emptyState
            }
        }
        .overlay {
            // Dropping works on the whole pane, in every state, so there is no
            // wrong place to let go.
            if engine.dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.brand.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .padding(14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0), value: engine.dropTargeted)
        .animation(.spring(duration: 0.3, bounce: 0), value: engine.selected?.id)
        .dropDestination(for: URL.self) { urls, _ in
            engine.select(dropped: urls)
        } isTargeted: { targeted in
            Task { @MainActor in engine.dropTargeted = targeted }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.14))
                Image(systemName: "trash.square")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.brand.gradient)
            }
            .frame(width: 84, height: 84)

            Text("Pick an app").font(.system(size: 19, weight: .semibold, design: .rounded))
            Text("You will see the app and everything it left in your Library, with sizes, before anything moves. Or drop a .app here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text("Only exact matches are listed. Everything goes to the Trash, so it can be put back.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - A chosen app

private struct SelectedApp: View {
    @ObservedObject var engine: UninstallEngine
    let app: InstalledApp

    var body: some View {
        VStack(spacing: 0) {
            header
            if let why = engine.refusal {
                refusalCard(why)
                Spacer(minLength: 0)
            } else {
                items
            }
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: AppIconCache.icon(forPath: app.url.path))
                .resizable().frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(app.bundleID ?? "No bundle identifier")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    engine.confirming = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash")
                        Text(engine.trashing ? "Moving…" : "Move to Trash").fontWeight(.semibold)
                    }
                    .frame(minWidth: 128)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.brand)
                .disabled(!engine.canTrash)

                Button {
                    engine.revealSelected()
                } label: {
                    Label("Show in Finder", systemImage: "magnifyingglass").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = app.version { parts.append("Version \(v)") }
        parts.append(UninstallText.lastUsed(app.lastUsed))
        return parts.joined(separator: " · ")
    }

    // MARK: Refusal

    private func refusalCard(_ why: Refusal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: why == .running ? "play.circle.fill" : "lock.fill")
                .font(.system(size: 18)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(why.message(for: app.name))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if why == .running {
                    Button("Check again") { engine.recheck() }.controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1) }
        .padding(.horizontal, 22).padding(.vertical, 8)
    }

    // MARK: Items

    private var items: some View {
        List {
            Section {
                TickRow(engine: engine, id: app.id, icon: AppIconCache.icon(forPath: app.url.path),
                        title: "\(app.name).app", subtitle: UninstallText.tilde(app.url.path),
                        kind: "App", bytes: app.bytes)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)

                if engine.scanningLeftovers {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for leftovers…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 36).padding(.vertical, 10)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    ForEach(engine.leftovers) { item in
                        TickRow(engine: engine, id: item.id, icon: nil,
                                title: item.name, subtitle: UninstallText.tilde(item.url.deletingLastPathComponent().path),
                                kind: item.kind, bytes: item.bytes)
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    if engine.leftovers.isEmpty {
                        Text("No leftovers found in your Library. Only exact matches on the app's bundle id or name are checked.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.horizontal, 36).padding(.vertical, 10)
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    if engine.ignoredCount > 0 {
                        Text("\(engine.ignoredCount) matching \(engine.ignoredCount == 1 ? "link" : "links") "
                             + "left alone, because \(engine.ignoredCount == 1 ? "it points" : "they point") somewhere else.")
                            .font(.caption).foregroundStyle(.orange)
                            .padding(.horizontal, 36).padding(.vertical, 6)
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
            } header: {
                HStack {
                    Text("WILL BE MOVED TO THE TRASH")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.5)
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.vertical, 7)
                .background(.bar)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if engine.refusal == nil {
                let everything = engine.ticked.count == 1 + engine.leftovers.count
                Button(everything ? "Untick all" : "Tick all") {
                    engine.ticked = everything ? [] : Set([app.id] + engine.leftovers.map(\.id))
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .disabled(engine.scanningLeftovers)

                Text("\(engine.chosenCount) ticked · \(fmtBytes(engine.chosenBytes))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text("Moved to the Trash, never deleted. System-wide files in /Library are not handled.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - A tickable line

private struct TickRow: View {
    @ObservedObject var engine: UninstallEngine
    let id: String
    let icon: NSImage?
    let title: String
    let subtitle: String
    let kind: String
    let bytes: UInt64?
    @StateObject private var hover = RowHover()

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { engine.ticked.contains(id) },
                set: { _ in engine.toggle(id) }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .accessibilityLabel("Select \(title)")
            .accessibilityValue(bytes.map(fmtBytes) ?? "")

            if let icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14)).foregroundStyle(Color.brand.opacity(0.75))
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(kind)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(bytes.map(fmtBytes) ?? "…")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hover.on ? Color.primary.opacity(0.05) : Color.primary.opacity(0.028))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hover.on ? Color.brand.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
        }
        .padding(.horizontal, 22).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { engine.toggle(id) }
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: hover.on)
    }
}

// MARK: - After removal

private struct ResultCard: View {
    @ObservedObject var engine: UninstallEngine
    let result: UninstallResult

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: result.moved.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(result.moved.isEmpty ? Color.orange : Color.brand)
                    .padding(.top, 40)

                Text(headline).font(.system(size: 19, weight: .semibold, design: .rounded))

                if !result.moved.isEmpty {
                    Text("\(fmtBytes(result.bytes)) comes back when you empty the Trash. Nothing was deleted.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if !result.moved.isEmpty {
                        Button("Undo") { engine.undo() }
                            .buttonStyle(.borderedProminent).tint(Color.brand)
                        Button("Show in Trash") { engine.revealInTrash() }
                    }
                    Button("Done") { engine.dismissResult() }
                }
                .controlSize(.large)
                .padding(.top, 4)

                if !result.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NOT MOVED (\(result.skipped.count))")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange).kerning(0.5)
                        ForEach(result.skipped, id: \.path) { skipped in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(UninstallText.tilde(skipped.path))
                                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(skipped.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(14)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.bottom, 30)
        }
    }

    private var headline: String {
        let n = result.moved.count
        if n == 0 { return "Nothing was moved." }
        return "Moved \(n) \(n == 1 ? "item" : "items") to the Trash."
    }
}
