import SwiftUI

struct ProjectView: View {
    @ObservedObject var engine: ProjectEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            cutoffBar
            if engine.capped { cappedNotice }
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
        .overlay(alignment: .bottom) {
            if let report = engine.report {
                Toast(text: report).padding(.bottom, 56)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: engine.report)
        .confirmationDialog(
            "Move \(engine.selectedItems.count) folder\(engine.selectedItems.count == 1 ? "" : "s") to the Trash?",
            isPresented: $engine.confirming
        ) {
            Button("Move to Trash") { engine.moveToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(fmtBytes(engine.selectedBytes)) in total. Nothing is deleted: use Put Back in the "
                 + "Trash to undo it. Each folder is checked again just before it moves. If you "
                 + "edited files inside one by hand, those edits go with it.")
        }
        .onAppear { if engine.lastScan == nil { engine.scan() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.14))
                Image(systemName: "hammer.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.brand.gradient)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(engine.scanning && engine.items.isEmpty ? "-" : fmtBytes(engine.totalBytes))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .kerning(-0.6)
                        .foregroundStyle(Color.brand)
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
                        Image(systemName: "trash")
                        Text(engine.trashing ? "Moving…" : "Move to Trash").fontWeight(.semibold)
                    }
                    .frame(minWidth: 136)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Teal, not red: this one can be undone.
                .tint(Color.brand)
                .disabled(engine.selection.isEmpty || engine.trashing || engine.scanning)

                Button {
                    engine.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Same reasoning as the Disk tab: a rescan mid-move would race
                // the one that move starts when it finishes.
                .disabled(engine.scanning || engine.trashing)
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
        if engine.scanning { return "Looking through your project folders…" }
        if engine.scannedRoots.isEmpty { return "No project folders found. Add one below." }
        if engine.items.isEmpty { return "Nothing here has sat untouched for \(engine.cutoffDays) days." }
        var s = engine.selection.isEmpty
            ? "Nothing ticked. Pick what to move."
            : "\(engine.selectedItems.count) selected · \(fmtBytes(engine.selectedBytes))"
        if engine.skippedRecent > 0 {
            s += " · \(engine.skippedRecent) skipped, changed in the last 24 hours"
        }
        return s
    }

    // MARK: - Cutoff

    private var cutoffBar: some View {
        HStack(spacing: 10) {
            Text("Untouched for at least")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("", selection: $engine.cutoffDays) {
                ForEach(ProjectEngine.cutoffChoices, id: \.self) { Text("\($0) days").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .accessibilityLabel("Untouched for at least")
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 6)
    }

    private var cappedNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Stopped early because these folders are very large. The list may be incomplete, "
                 + "and sizes marked ≥ are a minimum.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 22).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - List

    @ViewBuilder private var content: some View {
        if engine.scanning && engine.items.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for old build folders…").font(.callout).foregroundStyle(.secondary)
                Text("Reading folder names and dates only, not your code.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text(engine.scannedRoots.isEmpty ? "No project folders found."
                                                 : "Nothing to move.")
                    .foregroundStyle(.secondary)
                Text(engine.scannedRoots.isEmpty
                     ? "Boost looks in ~/Developer, ~/Projects, ~/code and a few similar places."
                     : "Try a shorter time, or add another folder.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(engine.items) { item in
                    ProjectRow(engine: engine, item: item)
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
        HStack(spacing: 14) {
            Button(!engine.items.isEmpty && engine.selection.count == engine.items.count
                   ? "Select none" : "Select all") {
                engine.setAll(engine.selection.count != engine.items.count)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(engine.items.isEmpty)

            Button {
                engine.addFolder()
            } label: {
                Label("Add Folder", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Also look inside a folder of your own")

            if !engine.extraRoots.isEmpty {
                Menu {
                    ForEach(engine.extraRoots, id: \.self) { path in
                        Button("Stop scanning \((path as NSString).abbreviatingWithTildeInPath)") {
                            engine.removeFolder(path)
                        }
                    }
                } label: {
                    Text("\(engine.extraRoots.count) added")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            Text("Goes to the Trash, so you can put it back.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - Row

private struct ProjectRow: View {
    @ObservedObject var engine: ProjectEngine
    let item: ProjectItem
    @StateObject private var hover = RowHover()

    private var idle: String {
        item.idleDays == 1 ? "untouched for 1 day" : "untouched for \(item.idleDays) days"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { engine.selection.contains(item.id) },
                set: { _ in engine.toggle(item) }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .padding(.top, 1)
            .accessibilityLabel("Select \(item.projectName) \(item.kind.label)")
            .accessibilityValue(fmtBytes(item.bytes))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.projectName).font(.system(size: 13, weight: .medium))
                    Text(item.kind.label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.brand.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.brand)
                }
                Text((item.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.kind.regeneration)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text((item.sizeCapped ? "≥ " : "") + fmtBytes(item.bytes))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(idle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .trailing)
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
        .onTapGesture { engine.toggle(item) }
        .help(item.url.path)
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: hover.on)
    }
}
