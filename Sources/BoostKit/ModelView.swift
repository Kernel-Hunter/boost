import SwiftUI
import AppKit

struct ModelView: View {
    @ObservedObject var engine: ModelEngine

    var body: some View {
        VStack(spacing: 0) {
            if engine.hasScanned {
                header
                notices
            }
            content
            if engine.hasScanned { footer }
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
            "Move \(engine.selectedItems.count) model\(engine.selectedItems.count == 1 ? "" : "s") to the Trash?",
            isPresented: $engine.confirming
        ) {
            Button("Move to Trash") { engine.moveToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(fmtBytes(engine.selectedBytes)) comes back once the Trash is emptied. "
                 + "Models are downloaded, not built, so using one again means downloading "
                 + "about \(fmtBytes(engine.selectedBytes)) again. They go to the Trash, so you "
                 + "can put them back from there. Each one is checked again just before it moves."
                 + (engine.selectionHasOllama ? " Close Ollama first if a model is downloading." : ""))
        }
        // No .onAppear scan. The user starts it.
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.14))
                Image(systemName: "cpu")
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
                    Text("in local AI models").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                engine.scan(keeping: engine.selection)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // A rescan mid-move would race the list the move is about to edit.
            .disabled(engine.scanning || engine.trashing)
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
        if engine.scanning { return "Looking through your model folders…" }
        if engine.items.isEmpty { return "No models found." }
        return engine.selection.isEmpty
            ? "Nothing ticked. Pick what to move."
            : "\(engine.selectedItems.count) selected · \(fmtBytes(engine.selectedBytes))"
    }

    // MARK: - Notices

    @ViewBuilder private var notices: some View {
        if engine.hasOllama {
            notice("Close Ollama first if a model is downloading.")
            notice("Ollama models share files. A model's size here is what removing it frees.")
        }
        if engine.ollamaDownloading {
            notice("An Ollama download looks to be running. Removing Ollama models is paused until it ends.")
        }
        if engine.skippedRecent > 0 {
            notice("\(engine.skippedRecent) left out because they changed in the last minute.")
        }
        if engine.skippedMalformed > 0 {
            notice("\(engine.skippedMalformed) Ollama manifest\(engine.skippedMalformed == 1 ? "" : "s") "
                   + "could not be read and \(engine.skippedMalformed == 1 ? "is" : "are") left alone.")
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 22).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !engine.hasScanned && !engine.scanning {
            intro
        } else if engine.scanning && engine.items.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for AI models…").font(.callout).foregroundStyle(.secondary)
                Text("Reading file names, sizes and dates only. Model files are not opened.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cpu").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("No local AI models found.").foregroundStyle(.secondary)
                Text(engine.lookedIn.isEmpty
                     ? "None of the Ollama, Hugging Face or LM Studio folders exist in your home folder."
                     : "Looked in " + engine.lookedIn
                        .map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        .joined(separator: ", ") + ".")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(engine.items) { item in
                    ModelRow(engine: engine, item: item)
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
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.14))
                Image(systemName: "cpu")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.brand.gradient)
            }
            .frame(width: 84, height: 84)

            Text("See the AI models on your Mac")
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Text("Boost looks for models downloaded by Ollama, Hugging Face and LM Studio, "
                 + "all inside your home folder. It reads names, sizes and dates only. "
                 + "Nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Text("Models are downloaded, not built, so removing one means downloading it again. "
                 + "Nothing is moved until you pick models and confirm. Moved models go to the Trash.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Button {
                engine.scan()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    Text("Scan").fontWeight(.semibold)
                }
                .frame(minWidth: 120)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.brand)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
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

            Text(engine.selection.isEmpty
                 ? "Goes to the Trash, so you can put it back."
                 : "\(engine.selectedItems.count) selected · \(fmtBytes(engine.selectedBytes)) to download again")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

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
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            // Teal, not red: this one can be undone.
            .tint(Color.brand)
            .disabled(engine.selection.isEmpty || engine.trashing || engine.scanning)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - Row

private struct ModelRow: View {
    @ObservedObject var engine: ModelEngine
    let item: ModelItem
    @StateObject private var hover = RowHover()

    private var sourceLine: String {
        let kind = item.kind == .model ? "" : " \(item.kind.title.lowercased())"
        return item.source.title + kind
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { engine.selection.contains(item.id) },
                set: { _ in engine.toggle(item) }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .accessibilityLabel("Select \(item.name)")
            .accessibilityValue(fmtBytes(item.bytes))

            Image(systemName: item.kind == .model ? "cpu" : "tray.full")
                .font(.system(size: 17))
                .foregroundStyle(Color.brand)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(sourceLine)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.brand.opacity(0.14)))
                        .foregroundStyle(Color.brand)
                    Text(((item.source == .ollama ? item.root : item.folder).path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let shared = ModelScan.sharedText(for: item) {
                    Text(shared)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text((item.sizeCapped ? "At least " : "") + fmtBytes(item.bytes))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(ModelScan.ageText(for: item))
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
        .contextMenu {
            Button("Show in Finder") { engine.reveal(item) }
            Button(engine.selection.contains(item.id) ? "Untick" : "Tick") { engine.toggle(item) }
        }
        .help(item.url.path)
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: hover.on)
    }
}
