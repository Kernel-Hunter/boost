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
        ReclaimHeader(
            symbol: "cpu",
            value: engine.scanning && engine.items.isEmpty ? "-" : fmtBytes(engine.totalBytes),
            unit: "in local AI models", subtitle: subtitle, busy: engine.scanning || engine.trashing
        ) {
            Button {
                engine.scan(keeping: engine.selection)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(QuietButtonStyle())
            // A rescan mid-move would race the list the move is about to edit.
            .disabled(engine.scanning || engine.trashing)
        }
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
                Text("Looking for AI models…").font(.callout).foregroundStyle(.secondary)
                Text("Reading file names, sizes and dates only. Model files are not opened.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.items.isEmpty {
            EmptyStateView(
                symbol: "cpu", title: "No local AI models found.",
                detail: engine.lookedIn.isEmpty
                    ? "None of the Ollama, Hugging Face or LM Studio folders exist in your home folder."
                    : "Looked in " + engine.lookedIn
                        .map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        .joined(separator: ", ") + ".")
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
        EmptyStateView(
            symbol: "cpu",
            title: "See the AI models on your Mac",
            detail: "Boost looks for models downloaded by Ollama, Hugging Face and LM Studio, "
                + "all inside your home folder. It reads names, sizes and dates only. "
                + "Nothing leaves your Mac."
        ) {
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
                     : "\(engine.selectedItems.count) selected · \(fmtBytes(engine.selectedBytes)) to download again")
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
                    Tag(sourceLine, Color.brand)
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
