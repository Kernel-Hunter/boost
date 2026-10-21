import Foundation
import AppKit
import SwiftUI

/// State for the Large Files tab. Same shape as `ProjectEngine`: a scan that
/// runs off the main actor, nothing ticked by default, and a report of what
/// happened.
///
/// One difference: nothing here runs until the user asks. Downloads, Desktop and
/// Documents raise macOS permission prompts the first time they are read, so the
/// tab opens on an explanation and a Scan button, never on a scan.
@MainActor
public final class LargeFileEngine: ObservableObject {
    public static let shared = LargeFileEngine()

    /// Minimum sizes offered, in megabytes. 1024 is 1 GB.
    public static let sizeChoices = [100, 250, 500, 1024]
    private static let sizeKey = "largeFileMinMB"

    public static func label(forMB mb: Int) -> String {
        mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    @Published public private(set) var items: [LargeFileItem] = []
    @Published public private(set) var scanning = false
    @Published public private(set) var trashing = false
    @Published public var selection: Set<String> = []
    @Published public private(set) var lastScan: Date?
    @Published public private(set) var capped = false
    @Published public private(set) var matches = 0
    @Published public private(set) var skippedRecent = 0
    @Published public var report: String?
    @Published public var confirming = false

    @Published public var sort: LargeFileSort = .size

    /// How big a file must be to be listed.
    @Published public var minMB: Int {
        didSet {
            guard oldValue != minMB else { return }
            UserDefaults.standard.set(minMB, forKey: Self.sizeKey)
            // Before the first scan this only remembers the choice. After it,
            // the list is out of date, and the permissions were already given.
            if lastScan != nil, !trashing { scan() }
        }
    }

    private var scanTask: Task<Void, Never>?

    public init() {
        let saved = UserDefaults.standard.integer(forKey: Self.sizeKey)
        minMB = Self.sizeChoices.contains(saved) ? saved : 250
    }

    public var hasScanned: Bool { lastScan != nil }
    public var minBytes: UInt64 { UInt64(minMB) * 1_048_576 }

    public var sortedItems: [LargeFileItem] { LargeFileScan.sorted(items, by: sort) }
    public var selectedItems: [LargeFileItem] { items.filter { selection.contains($0.id) } }
    public var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: - Scanning

    /// Only ever called from a button, or from a size change after a scan.
    public func scan() {
        // A new scan supersedes the running one (the size changed). The old
        // task is told to stop and its late result ignored.
        scanTask?.cancel()
        scanning = true
        let minBytes = self.minBytes
        scanTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                // Roots are found here, not on the main actor: the first read
                // of a protected folder can wait on a permission prompt.
                LargeFileScan.scan(roots: LargeFileScan.roots(), minBytes: minBytes,
                                   isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            if Task.isCancelled || result.cancelled { return }

            self.items = result.items
            self.capped = result.capped
            self.matches = result.matches
            self.skippedRecent = result.skippedRecent
            // Nothing is ticked for you. These are your own files; opting in
            // should be a decision, not the default.
            self.selection = []
            self.lastScan = Date()
            self.scanning = false
        }
    }

    // MARK: - Finder

    public func reveal(_ item: LargeFileItem) {
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
                LargeFileScan.moveToTrash(chosen, roots: LargeFileScan.roots())
            }.value

            var lines: [String] = []
            if r.moved > 0 {
                lines.append("Moved \(r.moved) file\(r.moved == 1 ? "" : "s") "
                           + "(\(fmtBytes(r.bytes))) to the Trash. Empty the Trash to get the space back.")
            } else {
                lines.append("Nothing was moved.")
            }
            if !r.skippedRecent.isEmpty {
                lines.append("\(r.skippedRecent.count) skipped because they changed recently.")
            }
            if !r.failed.isEmpty {
                lines.append("\(r.failed.count) could not be moved.")
            }
            if !r.refused.isEmpty {
                // Should be unreachable unless the disk changed after the scan.
                lines.append("\(r.refused.count) refused by the safety check.")
            }
            self.say(lines.joined(separator: " "))

            // Drop what moved instead of walking the folders again. Anything
            // skipped stays listed, and ticked, so the user can decide.
            let gone = Set(r.movedPaths)
            self.items.removeAll { gone.contains($0.id) }
            self.selection.subtract(gone)
            self.matches = max(self.items.count, self.matches - r.moved)
            self.trashing = false
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

    public func toggle(_ item: LargeFileItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
    }

    public func setAll(_ on: Bool) {
        selection = on ? Set(items.map(\.id)) : []
    }
}
