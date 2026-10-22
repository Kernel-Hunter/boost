import SwiftUI
import AppKit

struct DiskView: View {
    @ObservedObject var engine: DiskEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            if let docker = engine.dockerImage {
                DockerInfoRow(image: docker)
            }
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
            Text(confirmMessage)
        }
        .onAppear { if engine.lastScan == nil { engine.scan() } }
    }

    private var confirmMessage: String {
        let chosen = engine.selectedTargets
        if chosen.contains(where: \.userData) {
            return "This includes Xcode Archives, which are your own builds and their debug "
                 + "symbols. Nothing rebuilds them. They go to the Trash, so you can put them "
                 + "back until you empty it. Without the symbols, crash reports from those "
                 + "releases can not be read."
        }
        if chosen.contains(where: { !$0.regenerates }) {
            return "This includes your Trash, which is not regenerable. Everything else "
                 + "will be rebuilt by the app that owns it."
        }
        return "These are caches. The apps that own them will rebuild what they need."
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
            // `allSafeSelected` is false when there is nothing to select, so a
            // disabled button never reads "Select none". "Select all" leaves
            // user data (Xcode Archives) alone; that row is ticked by hand.
            Button(engine.allSafeSelected ? "Select none" : "Select all") {
                engine.setAll(!engine.allSafeSelected)
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
                    if target.userData {
                        Text("your data, not a cache")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                            .foregroundStyle(.orange)
                    } else if !target.regenerates {
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
                .strokeBorder(target.userData
                              ? Color.orange.opacity(hover.on ? 0.55 : 0.30)
                              : (hover.on ? Color.brand.opacity(0.35) : Color.primary.opacity(0.05)),
                              lineWidth: 1)
        }
        .padding(.horizontal, 22).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { engine.toggle(target) }
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: hover.on)
    }
}

// MARK: - Docker (information only)

/// Docker keeps everything in one large file. Boost reads its size and shows it,
/// and has no way to delete it: the row has no checkbox and the path is not in
/// the allowlist. Freeing the space is Docker's job.
private struct DockerInfoRow: View {
    let image: DiskScan.DockerImage
    @StateObject private var copied = RowHover()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Docker disk image").font(.system(size: 13, weight: .medium))
                Text("Docker keeps its images in one large file. Free that space from Docker "
                     + "itself: docker system prune.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(copied.on ? "Copied" : "Copy Command") { copy() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Text("up to \(fmtBytes(image.bytes))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.028)))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .padding(.horizontal, 22).padding(.vertical, 4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiskScan.dockerPruneCommand, forType: .string)
        copied.on = true
        let flag = copied
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            flag.on = false
        }
    }
}
