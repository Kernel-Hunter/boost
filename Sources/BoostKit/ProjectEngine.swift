import Foundation
import AppKit
import SwiftUI

/// State for the Projects tab. Same shape as `DiskEngine`: a scan that runs off
/// the main actor, nothing ticked by default, and a report of what happened.
@MainActor
public final class ProjectEngine: ObservableObject {
    public static let shared = ProjectEngine()

    public static let cutoffChoices = [30, 60, 90, 180]
    private static let rootsKey = "projectExtraRoots"
    private static let cutoffKey = "projectCutoffDays"

    @Published public private(set) var items: [ProjectItem] = []
    @Published public private(set) var scanning = false
    @Published public private(set) var trashing = false
    @Published public var selection: Set<String> = []
    @Published public private(set) var lastScan: Date?
    @Published public private(set) var capped = false
    @Published public private(set) var skippedRecent = 0
    @Published public private(set) var scannedRoots: [URL] = []
    @Published public var report: String?
    @Published public var confirming = false

    /// How long a project must have been untouched to be listed.
    @Published public var cutoffDays: Int {
        didSet {
            guard oldValue != cutoffDays else { return }
            UserDefaults.standard.set(cutoffDays, forKey: Self.cutoffKey)
            scan()
        }
    }

    /// Folders the user added with Add Folder, on top of the usual places.
    @Published public private(set) var extraRoots: [String]

    private var scanTask: Task<Void, Never>?

    public init() {
        let saved = UserDefaults.standard.integer(forKey: Self.cutoffKey)
        cutoffDays = Self.cutoffChoices.contains(saved) ? saved : 60
        extraRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []
    }

    public var selectedItems: [ProjectItem] { items.filter { selection.contains($0.id) } }
    public var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: - Scanning

    public func scan() {
        // A new scan supersedes the running one (the cutoff changed, or folders
        // were added). The old task is told to stop and its late result ignored.
        scanTask?.cancel()
        scanning = true
        let roots = ProjectScan.roots(extra: extraRoots)
        let days = cutoffDays
        scanTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                ProjectScan.scan(roots: roots, olderThanDays: days,
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
            self.skippedRecent = result.skippedRecent
            self.scannedRoots = roots
            // Nothing is ticked for you. This moves folders out of your
            // projects; opting in should be a decision, not the default.
            self.selection = []
            self.lastScan = Date()
            self.scanning = false
        }
    }

    // MARK: - Folders

    /// Lets the user point the scan at a folder of their own. The panel is the
    /// consent: Boost only ever reads inside folders it was given.
    public func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder that holds your projects."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard ProjectScan.isAcceptableRoot(url) else {
            say("That folder is too broad to scan. Pick the one that holds your projects.")
            return
        }
        let path = ProjectScan.canonical(url).path
        guard !extraRoots.contains(path) else { return }
        extraRoots.append(path)
        UserDefaults.standard.set(extraRoots, forKey: Self.rootsKey)
        scan()
    }

    public func removeFolder(_ path: String) {
        extraRoots.removeAll { $0 == path }
        UserDefaults.standard.set(extraRoots, forKey: Self.rootsKey)
        scan()
    }

    // MARK: - Moving to the Trash

    public func moveToTrash() {
        let chosen = selectedItems
        guard !chosen.isEmpty, !trashing else { return }
        trashing = true
        // Roots and cutoff are read again here, not reused from the scan, so
        // the safety check judges against the settings in force right now.
        let roots = ProjectScan.roots(extra: extraRoots)
        let days = cutoffDays
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                ProjectScan.moveToTrash(chosen, roots: roots, olderThanDays: days)
            }.value

            var lines: [String] = []
            if r.moved > 0 {
                lines.append("Moved \(r.moved) folder\(r.moved == 1 ? "" : "s") "
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
            self.trashing = false
            self.scan()          // re-measure rather than assume it all went
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

    public func toggle(_ item: ProjectItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
    }

    public func setAll(_ on: Bool) {
        selection = on ? Set(items.map(\.id)) : []
    }
}
