import Foundation
import SwiftUI

/// State for the disk tab. Kept apart from `Engine` because the two have
/// nothing to do with each other: one signals processes, this one measures and
/// removes files, and a scan takes seconds where a process sample takes
/// milliseconds.
@MainActor
public final class DiskEngine: ObservableObject {
    public static let shared = DiskEngine()

    @Published public private(set) var targets: [CleanupTarget] = []
    @Published public private(set) var scanning = false
    @Published public private(set) var cleaning = false
    @Published public var selection: Set<String> = []
    @Published public private(set) var lastScan: Date?
    @Published public var report: String?
    @Published public var confirming = false

    public var selectedTargets: [CleanupTarget] { targets.filter { selection.contains($0.id) } }
    public var selectedBytes: UInt64 { selectedTargets.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: UInt64 { targets.reduce(0) { $0 + $1.bytes } }

    public func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            // Walking every cache directory is seconds of file IO, not
            // microseconds of arithmetic. It does not belong on the main actor.
            let found = await Task.detached(priority: .userInitiated) {
                DiskScan.scan()
            }.value

            self.targets = found
            // Nothing is ticked for you. This deletes files; opting in should be
            // a decision rather than the default that happens to be on screen.
            self.selection = []
            self.lastScan = Date()
            self.scanning = false
        }
    }

    public func clean() {
        let chosen = selectedTargets
        guard !chosen.isEmpty, !cleaning else { return }
        cleaning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DiskScan.clean(chosen)
            }.value

            var lines = ["Freed \(fmtBytes(result.freed)) from \(result.removed) items."]
            if !result.failed.isEmpty {
                lines.append("\(result.failed.count) in use and left alone.")
            }
            if !result.refused.isEmpty {
                // Should be unreachable: the targets are checked against the
                // same guard by a test. If it ever fires, something changed.
                lines.append("\(result.refused.count) refused by the safety check.")
            }
            self.report = lines.joined(separator: " ")
            self.cleaning = false
            self.scan()          // re-measure rather than assume it all went
        }
    }

    public func toggle(_ target: CleanupTarget) {
        if selection.contains(target.id) { selection.remove(target.id) }
        else { selection.insert(target.id) }
    }

    public func setAll(_ on: Bool) {
        selection = on ? Set(targets.map(\.id)) : []
    }
}
