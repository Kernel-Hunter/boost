import SwiftUI

struct DiskView: View {
    @ObservedObject var engine: DiskEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .boostBottomBar { footer }
        }
        .boostBackdrop()
        .confirmationDialog("Delete \(fmtBytes(engine.selectedBytes))?",
                            isPresented: $engine.confirming) {
            Button("Delete", role: .destructive) { engine.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(engine.selectedTargets.contains { !$0.regenerates }
                 ? "This includes your Trash, which is not regenerable. Everything else "
                 + "will be rebuilt by the app that owns it."
                 : "These are caches. The apps that own them will rebuild what they need.")
        }
        .onAppear { if engine.lastScan == nil { engine.scan() } }
    }

    // MARK: - Header

    private var header: some View {
        ReclaimHeader(
            symbol: "internaldrive.fill",
            value: engine.scanning ? "-" : fmtBytes(engine.totalBytes),
            unit: "reclaimable", subtitle: subtitle, busy: engine.scanning || engine.cleaning
        ) {
            Button {
                engine.confirming = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "trash.fill")
                    Text(engine.cleaning ? "Cleaning…" : "Clean").fontWeight(.semibold)
                }
                .frame(minWidth: 116)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(engine.selection.isEmpty || engine.cleaning || engine.scanning)

            Button {
                engine.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(QuietButtonStyle())
            // Clean already re-scans when it finishes (see DiskEngine.clean);
            // a manual rescan started mid-clean would race that one and get
            // silently dropped by scan()'s own re-entrancy guard, leaving the
            // list stale with nothing telling you why.
            .disabled(engine.scanning || engine.cleaning)
        }
    }

    private var subtitle: String {
        if engine.scanning { return "Measuring…" }
        if engine.targets.isEmpty { return "Nothing worth reclaiming." }
        return engine.selection.isEmpty
            ? "Nothing ticked. Pick what to remove."
            : "\(engine.selectedTargets.count) selected · \(fmtBytes(engine.selectedBytes))"
    }

    // MARK: - List

    @ViewBuilder private var content: some View {
        if engine.scanning && engine.targets.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Measuring caches…").font(.callout).foregroundStyle(.secondary)
                Text("Walking a few hundred thousand files. A moment.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.targets.isEmpty {
            EmptyStateView(symbol: "internaldrive", title: "Nothing to clean.",
                           detail: "No caches large enough to bother with.")
        } else {
            List {
                ForEach(engine.targets) { target in
                    DiskRow(engine: engine, target: target)
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

    // MARK: - Footer

    private var footer: some View {
        FloatingBar {
            Button(!engine.targets.isEmpty && engine.selection.count == engine.targets.count
                   ? "Select none" : "Select all") {
                engine.setAll(engine.selection.count != engine.targets.count)
            }
            .boostButton()
            .controlSize(.regular)
            .disabled(engine.targets.isEmpty)

            Spacer()

            InfoPill {
                Text("Deleting is not reversible.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Row

private struct DiskRow: View {
    @ObservedObject var engine: DiskEngine
    let target: CleanupTarget
    // Scoped per row so hovering repaints that row alone, and an
    // ObservableObject rather than @State for the reason in Views.swift.
    @StateObject private var hover = RowHover()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { engine.selection.contains(target.id) },
                set: { _ in engine.toggle(target) }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .padding(.top, 1)
            .accessibilityLabel("Select \(target.name)")
            .accessibilityValue(fmtBytes(target.bytes))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.name).font(.system(size: 13, weight: .medium))
                    if !target.regenerates {
                        Tag("not regenerable", .orange)
                    }
                }
                Text(target.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(fmtBytes(target.bytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .boostRow(hovered: hover.on)
        .padding(.horizontal, 22).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { engine.toggle(target) }
    }
}
