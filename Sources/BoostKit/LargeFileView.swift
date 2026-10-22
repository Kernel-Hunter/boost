import SwiftUI
import AppKit

/// Main-actor confined for the same reason as `IconCache` in Views.swift.
@MainActor
private enum FileIconCache {
    private static var store: [String: NSImage] = [:]
    static func icon(forPath path: String) -> NSImage {
        if let hit = store[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        store[path] = image
        return image
    }
}

struct LargeFileView: View {
    @ObservedObject var engine: LargeFileEngine

    var body: some View {
        VStack(spacing: 0) {
            if engine.hasScanned {
                header
                controlBar
                notices
            }
            content
                .boostBottomBar {
                    if engine.hasScanned { footer }
                }
        }
        .boostBackdrop()
        .overlay(alignment: .bottom) {
            if let report = engine.report {
                Toast(text: report).padding(.bottom, 56)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: engine.report)
        .confirmationDialog(
            "Move \(engine.selectedItems.count) file\(engine.selectedItems.count == 1 ? "" : "s") to the Trash?",
            isPresented: $engine.confirming
        ) {
            Button("Move to Trash") { engine.moveToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(fmtBytes(engine.selectedBytes)) in total. They go to the Trash, so you can "
                 + "put them back from there. Each file is checked again just before it moves.")
        }
        // No .onAppear scan. Reading Downloads, Desktop and Documents can raise
        // macOS permission prompts, so the user starts it.
    }

    // MARK: - Header

    private var header: some View {
        ReclaimHeader(
            symbol: "doc.text.magnifyingglass",
            value: engine.scanning && engine.items.isEmpty ? "-" : fmtBytes(engine.totalBytes),
            unit: "in large files", subtitle: subtitle, busy: engine.scanning || engine.trashing
        ) {
            Button {
                engine.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(QuietButtonStyle())
            // Same reasoning as the Projects tab: a rescan mid-move would race
            // the list the move is about to edit.
            .disabled(engine.scanning || engine.trashing)
        }
    }

    private var subtitle: String {
        if engine.scanning { return "Looking through your folders…" }
        if engine.items.isEmpty {
            return "No file is \(LargeFileEngine.label(forMB: engine.minMB)) or larger."
        }
        return engine.selection.isEmpty
            ? "Nothing ticked. Pick what to move."
            : "\(engine.selectedItems.count) selected · \(fmtBytes(engine.selectedBytes))"
    }

    // MARK: - Size and order

    private var controlBar: some View {
        HStack(spacing: 10) {
            Text("At least")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("", selection: $engine.minMB) {
                ForEach(LargeFileEngine.sizeChoices, id: \.self) {
                    Text(LargeFileEngine.label(forMB: $0)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .accessibilityLabel("Minimum file size")
            .disabled(engine.trashing)

            Spacer()

            Menu {
                Picker("Sort by", selection: $engine.sort) {
                    ForEach(LargeFileSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(engine.sort.title).font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 5)
            .boostGlassCapsule()
            .help("Sort the list by")
            .accessibilityLabel("Sort by")
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
    }

    @ViewBuilder private var notices: some View {
        if engine.capped {
            let named = engine.cappedFolders.isEmpty ? "these folders"
                : engine.cappedFolders.joined(separator: ", ")
            notice("Stopped early in \(named) because they hold a very large number of items. "
                   + "The list may be incomplete.")
        }
        if engine.matches > engine.items.count {
            notice("Showing the \(engine.items.count) largest of \(engine.matches) files.")
        }
        if engine.skippedRecent > 0 {
            notice("\(engine.skippedRecent) left out because they changed in the last minute.")
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !engine.hasScanned && !engine.scanning {
            intro
        } else if engine.scanning && engine.items.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for large files…").font(.callout).foregroundStyle(.secondary)
                Text("Reading file names, sizes and dates only. File contents are not opened.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.items.isEmpty {
            EmptyStateView(symbol: "doc.text.magnifyingglass", title: "No large files found.",
                           detail: "Try a smaller size.")
        } else {
            List {
                ForEach(engine.sortedItems) { item in
                    LargeFileRow(engine: engine, item: item)
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

    /// What the tab shows until the user starts a scan.
    private var intro: some View {
        EmptyStateView(
            symbol: "doc.text.magnifyingglass",
            title: "Find your largest files",
            detail: "Boost looks inside Downloads, Desktop, Documents, Movies, Music and Pictures. "
                + "macOS may ask permission for some of them. Nothing leaves your Mac."
        ) {
            Text("Nothing is moved until you pick files and confirm. Moved files go to the Trash.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Text("Files of at least")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $engine.minMB) {
                    ForEach(LargeFileEngine.sizeChoices, id: \.self) {
                        Text(LargeFileEngine.label(forMB: $0)).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .accessibilityLabel("Minimum file size")
            }
            .padding(.top, 6)

            Button {
                engine.scan()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    Text("Scan").fontWeight(.semibold)
                }
                .frame(minWidth: 120)
                .padding(.vertical, 5)
            }
            .boostProminentButton()
            .controlSize(.large)
            .padding(.top, 4)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        FloatingBar {
            Button(!engine.items.isEmpty && engine.selection.count == engine.items.count
                   ? "Select none" : "Select all") {
                engine.setAll(engine.selection.count != engine.items.count)
            }
            .boostButton()
            .disabled(engine.items.isEmpty)

            InfoPill {
                Text(engine.selection.isEmpty
                     ? "Goes to the Trash, so you can put it back."
                     : "\(engine.selectedItems.count) selected · \(fmtBytes(engine.selectedBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                engine.confirming = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "trash")
                    Text(engine.trashing ? "Moving…" : "Move to Trash").fontWeight(.semibold)
                }
                .frame(minWidth: 120)
            }
            // Teal, not red: this one can be undone.
            .boostProminentButton()
            .controlSize(.large)
            .disabled(engine.selection.isEmpty || engine.trashing || engine.scanning)
        }
    }
}

// MARK: - Row

private struct LargeFileRow: View {
    @ObservedObject var engine: LargeFileEngine
    let item: LargeFileItem
    @StateObject private var hover = RowHover()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { engine.selection.contains(item.id) },
                set: { _ in engine.toggle(item) }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .accessibilityLabel("Select \(item.name)")
            .accessibilityValue(fmtBytes(item.bytes))

            Image(nsImage: FileIconCache.icon(forPath: item.url.path))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((item.folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(fmtBytes(item.bytes))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(LargeFileScan.ageText(for: item))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 170, alignment: .trailing)

            Button {
                engine.reveal(item)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hover.on ? Color.brand : Color.secondary)
            .help("Show in Finder")
            .accessibilityLabel("Show \(item.name) in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .boostRow(hovered: hover.on)
        .padding(.horizontal, 22).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { engine.toggle(item) }
        .contextMenu {
            Button("Show in Finder") { engine.reveal(item) }
            Button(engine.selection.contains(item.id) ? "Untick" : "Tick") { engine.toggle(item) }
        }
        .help(item.url.path)
    }
}
