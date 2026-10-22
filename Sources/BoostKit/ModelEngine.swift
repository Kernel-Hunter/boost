import Foundation
import AppKit
import SwiftUI

/// State for the AI Models tab. Same shape as `LargeFileEngine`: a scan that
/// runs off the main actor, nothing ticked by default, and a report of what
/// happened.
///
/// Nothing here runs until the user asks. The tab opens on an explanation and a
/// Scan button, never on a scan.
@MainActor
public final class ModelEngine: ObservableObject {
    public static let shared = ModelEngine()

    @Published public private(set) var items: [ModelItem] = []
    @Published public private(set) var scanning = false
    @Published public private(set) var trashing = false
    @Published public var selection: Set<String> = []
    @Published public private(set) var lastScan: Date?
    @Published public private(set) var lookedIn: [URL] = []
    @Published public private(set) var skippedRecent = 0
    @Published public private(set) var skippedMalformed = 0
    @Published public private(set) var ollamaDownloading = false
    @Published public var report: String?
    @Published public var confirming = false

    private var scanTask: Task<Void, Never>?

    public init() {}

    public var hasScanned: Bool { lastScan != nil }

    public var selectedItems: [ModelItem] { items.filter { selection.contains($0.id) } }
    /// What taking the ticked models off the disk frees. Not the sum of the
    /// rows: Ollama models that share a file free it only together.
    public var selectedBytes: UInt64 { ModelScan.freedBytes(selectedItems) }
    /// What taking every listed model off the disk would free.
    public var totalBytes: UInt64 { ModelScan.freedBytes(items) }
    public var hasOllama: Bool { items.contains { $0.source == .ollama } }
    public var selectionHasOllama: Bool { selectedItems.contains { $0.source == .ollama } }

    // MARK: - Scanning

    /// Only ever called from a button, or to refresh the list after a move.
    public func scan(keeping kept: Set<String> = []) {
        scanTask?.cancel()
        scanning = true
        scanTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                // Roots are found here, not on the main actor, so a slow disk
                // never holds the window up.
                ModelScan.scan(roots: ModelScan.roots(), isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            if Task.isCancelled || result.cancelled { return }

            self.items = result.items
            self.lookedIn = result.lookedIn
            self.skippedRecent = result.skippedRecent
            self.skippedMalformed = result.skippedMalformed
            self.ollamaDownloading = result.ollamaDownloading
            // Nothing is ticked for you. After a move, what you had ticked and
            // is still listed stays ticked.
            self.selection = kept.intersection(Set(result.items.map(\.id)))
            self.lastScan = Date()
            self.scanning = false
        }
    }

    // MARK: - Finder

    public func reveal(_ item: ModelItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Moving to the Trash

    public func moveToTrash() {
        let chosen = selectedItems
        guard !chosen.isEmpty, !trashing, !scanning else { return }
        trashing = true
        Task {
            // Roots are read again here, not reused from the scan, so the
            // safety check judges against what is on disk right now.
            let r = await Task.detached(priority: .userInitiated) {
                ModelScan.moveToTrash(chosen, roots: ModelScan.roots())
            }.value

            var lines: [String] = []
            if r.moved > 0 {
                lines.append("Moved \(r.moved) model\(r.moved == 1 ? "" : "s") "
                           + "(\(fmtBytes(r.bytes))) to the Trash. Empty the Trash to get the space back.")
            } else {
                lines.append("Nothing was moved.")
            }
            if !r.skippedRecent.isEmpty {
                lines.append("\(r.skippedRecent.count) skipped because they changed in the last minute. "
                           + "A download may still be running.")
            }
            if !r.failed.isEmpty {
                lines.append("\(r.failed.count) item\(r.failed.count == 1 ? "" : "s") could not be moved.")
            }
            if !r.refused.isEmpty {
                // Should be unreachable unless the disk changed after the scan.
                lines.append("\(r.refused.count) refused by the safety check.")
            }
            self.say(lines.joined(separator: " "))

            let gone = Set(r.movedPaths)
            self.items.removeAll { gone.contains($0.id) }
            self.selection.subtract(gone)
            self.trashing = false
            // Removing one Ollama model can leave a shared file used by one
            // model only, so the sizes on the other rows are now out of date.
            // Read again to correct them. Read only, and the ticks stay.
            if r.moved > 0 { self.scan(keeping: self.selection) }
        }
    }

    /// Shows a message, then clears it. Long enough to read a two-sentence
    /// report, short enough not to sit over the list forever.
    private func say(_ text: String) {
        report = text
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if self.report == text { self.report = nil }
        }
    }

    // MARK: - Selection

    public func toggle(_ item: ModelItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
    }

    public func setAll(_ on: Bool) {
        selection = on ? Set(items.map(\.id)) : []
    }
}
