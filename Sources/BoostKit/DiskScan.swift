import Foundation

// MARK: - What may be removed

/// A category of reclaimable disk space.
///
/// Everything here has to satisfy one rule: **deleting it loses no work**. Either
/// the owning tool rebuilds it on demand (a package manager's download cache) or
/// it is already refuse (the Trash). Anything that is a judgement call — your
/// Downloads folder, a project's `node_modules`, an iPhone backup — is
/// deliberately absent, however much space it would score. An app that reclaims
/// 40 GB and takes one irreplaceable thing with it is a worse app than one that
/// reclaims 4 GB and never does.
public struct CleanupTarget: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Shown in the UI. Says what this is and what happens after it goes, so
    /// the decision is informed rather than trusting.
    public let detail: String
    public let paths: [URL]
    /// True when the owning tool simply rebuilds it. False for things that are
    /// merely finished with, like the Trash.
    public let regenerates: Bool
    public var bytes: UInt64 = 0

    public var isEmpty: Bool { bytes == 0 }
}

public enum DiskScan {

    // MARK: - The allowlist

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Every candidate. Paths that don't exist on a given Mac are dropped at
    /// scan time rather than listed as zero.
    public static func targets() -> [CleanupTarget] {
        let h = home
        return [
            CleanupTarget(
                id: "trash", name: "Trash",
                detail: "Files you already deleted. This is the only entry here that is not "
                      + "regenerable — if something in the Trash still matters, take it out first.",
                paths: [h.appending(path: ".Trash")],
                regenerates: false),

            CleanupTarget(
                id: "homebrew", name: "Homebrew downloads",
                detail: "Installer archives Homebrew keeps after installing. It re-downloads "
                      + "any it needs. Equivalent to `brew cleanup`.",
                paths: [h.appending(path: "Library/Caches/Homebrew")],
                regenerates: true),

            CleanupTarget(
                id: "xcode-derived", name: "Xcode DerivedData",
                detail: "Build intermediates and indexes. Xcode rebuilds them; the next build "
                      + "of each project will be a slow one.",
                paths: [h.appending(path: "Library/Developer/Xcode/DerivedData")],
                regenerates: true),

            CleanupTarget(
                id: "simulator-caches", name: "iOS Simulator caches",
                detail: "Cached simulator data. Does not touch the simulators themselves or "
                      + "anything installed in them.",
                paths: [h.appending(path: "Library/Developer/CoreSimulator/Caches")],
                regenerates: true),

            CleanupTarget(
                id: "js", name: "npm and Yarn caches",
                detail: "Package tarballs kept for reinstalls. Both re-download on demand. "
                      + "Does not touch any project's node_modules.",
                paths: [h.appending(path: ".npm/_cacache"),
                        h.appending(path: "Library/Caches/Yarn"),
                        h.appending(path: "Library/Caches/pnpm")],
                regenerates: true),

            CleanupTarget(
                id: "python", name: "pip and uv caches",
                detail: "Downloaded wheels and build artefacts. Both re-download on demand. "
                      + "Does not touch any virtualenv.",
                paths: [h.appending(path: "Library/Caches/pip"),
                        h.appending(path: ".cache/uv"),
                        h.appending(path: "Library/Caches/uv")],
                regenerates: true),

            CleanupTarget(
                id: "rust", name: "Cargo registry cache",
                detail: "Downloaded crate sources and archives. Cargo re-fetches what a build "
                      + "needs.",
                paths: [h.appending(path: ".cargo/registry/cache"),
                        h.appending(path: ".cargo/registry/src")],
                regenerates: true),

            CleanupTarget(
                id: "gradle", name: "Gradle caches",
                detail: "Downloaded dependencies and build caches. Gradle re-fetches them.",
                paths: [h.appending(path: ".gradle/caches")],
                regenerates: true),

            CleanupTarget(
                id: "app-caches", name: "Application caches",
                detail: "What apps keep under ~/Library/Caches so they need not redo work — "
                      + "thumbnails, decoded images, fetched data. Apps rebuild it. Some will "
                      + "feel slow once, and a few may want signing in to again.",
                paths: [h.appending(path: "Library/Caches")],
                regenerates: true),

            CleanupTarget(
                id: "logs", name: "Logs",
                detail: "Diagnostic logs written by apps. Worth keeping if you are in the "
                      + "middle of debugging something.",
                paths: [h.appending(path: "Library/Logs")],
                regenerates: true),
        ]
    }

    // MARK: - Safety

    /// The last line of defence before anything is removed.
    ///
    /// The allowlist above is the intended safety mechanism; this exists because
    /// an allowlist is only as good as the next edit to it. Every deletion is
    /// checked again, against the resolved path, immediately before it happens.
    ///
    /// Rejects anything that is not inside one of a few known-cache roots under
    /// the user's own home, and anything that resolves out of them — a symlink
    /// in a cache directory pointing at your documents is not hypothetical, it
    /// is how this kind of tool destroys data.
    public static func isSafeToDelete(_ url: URL, home overrideHome: URL? = nil) -> Bool {
        let h = (overrideHome ?? home).standardizedFileURL.resolvingSymlinksInPath()

        // Resolve before testing: the check must apply to where the path really
        // goes, not to what it is spelled as.
        let target = url.standardizedFileURL.resolvingSymlinksInPath()

        let homeParts = h.pathComponents
        let parts = target.pathComponents

        // Must be strictly inside the home directory.
        guard parts.count > homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts else {
            return false
        }
        // No ".." survived standardisation.
        guard !parts.contains("..") else { return false }

        let rest = Array(parts.dropFirst(homeParts.count))

        // Never the home directory itself, and never a bare top-level folder:
        // "~/Library" or "~/Documents" must be unreachable however we got here.
        guard rest.count >= 2 else { return rest == [".Trash"] }

        let allowedRoots: [[String]] = [
            [".Trash"],
            ["Library", "Caches"],
            ["Library", "Logs"],
            ["Library", "Developer", "Xcode", "DerivedData"],
            ["Library", "Developer", "CoreSimulator", "Caches"],
            [".npm", "_cacache"],
            [".cache", "uv"],
            [".cargo", "registry"],
            [".gradle", "caches"],
        ]
        return allowedRoots.contains { root in
            rest.count >= root.count && Array(rest.prefix(root.count)) == root
        }
    }

    // MARK: - Measuring

    /// Total size on disk of everything under `url`.
    ///
    /// Uses allocated size rather than logical size, so the number matches what
    /// the disk actually gets back. Skips symlinks instead of following them,
    /// so a link into a large tree elsewhere is not counted as this tree's.
    public static func size(of url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]

        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: Set(keys))
            return UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }

        var total: UInt64 = 0
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles]) else { return 0 }
        for case let child as URL in e {
            guard let v = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Measures every target. Slow enough (seconds, on a large cache) that it
    /// must not be called on the main thread.
    public static func scan() -> [CleanupTarget] {
        targets().map { target in
            var t = target
            t.bytes = target.paths.reduce(0) { $0 + size(of: $1) }
            return t
        }
        .filter { !$0.isEmpty }
    }

    // MARK: - Removing

    public struct CleanResult: Sendable {
        public var freed: UInt64 = 0
        public var removed: Int = 0
        public var refused: [String] = []
        public var failed: [String] = []
    }

    /// Empties the contents of each target, leaving the directory itself in
    /// place — tools expect their cache directory to exist.
    ///
    /// `dryRun` reports what would go without touching anything.
    public static func clean(_ targets: [CleanupTarget], dryRun: Bool = false) -> CleanResult {
        let fm = FileManager.default
        var result = CleanResult()

        for target in targets {
            for root in target.paths {
                guard fm.fileExists(atPath: root.path) else { continue }
                guard isSafeToDelete(root) else {
                    result.refused.append(root.path)
                    continue
                }
                let children = (try? fm.contentsOfDirectory(at: root,
                                                            includingPropertiesForKeys: nil,
                                                            options: [])) ?? []
                for child in children {
                    guard isSafeToDelete(child) else {
                        result.refused.append(child.path)
                        continue
                    }
                    let bytes = size(of: child)
                    if dryRun {
                        result.freed += bytes
                        result.removed += 1
                        continue
                    }
                    do {
                        try fm.removeItem(at: child)
                        result.freed += bytes
                        result.removed += 1
                    } catch {
                        // In use, or owned by another user. Not worth failing
                        // the whole run over — report and carry on.
                        result.failed.append(child.lastPathComponent)
                    }
                }
            }
        }
        return result
    }
}
