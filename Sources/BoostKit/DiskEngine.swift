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
    /// Docker Desktop's disk image, when there is one. Shown as information
    /// only; nothing in the engine can delete it.
    @Published public private(set) var dockerImage: DiskScan.DockerImage?

    public init(targets: [CleanupTarget] = []) {
        self.targets = targets
    }

    public var selectedTargets: [CleanupTarget] { targets.filter { selection.contains($0.id) } }
    public var selectedBytes: UInt64 { selectedTargets.reduce(0) { $0 + $1.bytes } }
    /// The headline number counts caches only. User data such as Xcode Archives
    /// has its own row and size and is not presented as space to reclaim.
    public var totalBytes: UInt64 { targets.filter { !$0.userData }.reduce(0) { $0 + $1.bytes } }
    /// True when every cache row is ticked. Ticking user data is separate.
    public var allSafeSelected: Bool {
        let safe = DiskScan.selectableIDs(targets)
        return !safe.isEmpty && safe.isSubset(of: selection)
    }

    public func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            // Walking every cache directory is seconds of file IO, not
            // microseconds of arithmetic. It does not belong on the main actor.
            let (found, docker) = await Task.detached(priority: .userInitiated) {
                (DiskScan.scan(), DiskScan.dockerImage())
            }.value

            self.targets = found
            self.dockerImage = docker
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

    /// "Select all" ticks the caches. It never ticks user data such as Xcode
    /// Archives; that row is opted into by hand. "Select none" clears everything.
    public func setAll(_ on: Bool) {
        if on { selection.formUnion(DiskScan.selectableIDs(targets)) }
        else { selection = [] }
    }
}
