import SwiftUI

struct DiskView: View {
    @ObservedObject var engine: DiskEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
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
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.14))
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.brand.gradient)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(engine.scanning ? "-" : fmtBytes(engine.totalBytes))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .kerning(-0.6)
                        .contentTransition(.numericText())
                    Text("reclaimable").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    engine.confirming = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash.fill")
                        Text(engine.cleaning ? "Cleaning…" : "Clean").fontWeight(.semibold)
                    }
                    .frame(minWidth: 116)
                    .padding(.vertical, 7)
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
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Clean already re-scans when it finishes (see DiskEngine.clean);
                // a manual rescan started mid-clean would race that one and get
                // silently dropped by scan()'s own re-entrancy guard, leaving the
                // list stale with nothing telling you why.
                .disabled(engine.scanning || engine.cleaning)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
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
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("Nothing to clean.").foregroundStyle(.secondary)
                Text("No caches large enough to bother with.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(spacing: 10) {
            // Guarded on `!targets.isEmpty` too: 0 selected of 0 targets
            // reads as "all selected" by the count comparison alone, which
            // would label a disabled button "Select none" while nothing is
            // selected and there's nothing to select.
            Button(!engine.targets.isEmpty && engine.selection.count == engine.targets.count
                   ? "Select none" : "Select all") {
                engine.setAll(engine.selection.count != engine.targets.count)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(engine.targets.isEmpty)

            Spacer()

            Text("Deleting is not reversible.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
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
                        Text("not regenerable")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                            .foregroundStyle(.orange)
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
        .onTapGesture { engine.toggle(target) }
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: hover.on)
    }
}
