import Foundation

// MARK: - Where the Large Files tab looks

/// The folders the Large Files tab reads.
///
/// `deep` folders are walked all the way down. `shallow` folders contribute
/// only the files that sit directly in them, which is how the home folder is
/// handled: its top level holds loose files, but below it sits `Library`, and
/// that is never ours to list.
public struct LargeFileRoots: Sendable, Equatable {
    public var deep: [URL]
    public var shallow: [URL]

    public init(deep: [URL], shallow: [URL] = []) {
        self.deep = deep
        self.shallow = shallow
    }

    public var isEmpty: Bool { deep.isEmpty && shallow.isEmpty }
}

// MARK: - Results

/// One row in the Large Files list. Always a regular file, never a folder.
public struct LargeFileItem: Identifiable, Sendable, Equatable {
    /// The file's path, which is unique and stable across rescans.
    public var id: String { url.path }
    public let url: URL
    /// Allocated size on disk, which is the space the Trash gives back.
    public let bytes: UInt64
    public let lastAccessed: Date?
    public let lastModified: Date?

    public var name: String { url.lastPathComponent }
    public var folder: URL { url.deletingLastPathComponent() }

    /// The newest sign the file was used. Saving a file counts as using it, so
    /// a recent edit wins over an old access date.
    public var lastUsed: Date? { [lastAccessed, lastModified].compactMap { $0 }.max() }
}

public struct LargeFileScanResult: Sendable {
    /// The largest matches, biggest first, at most `limit` of them.
    public var items: [LargeFileItem] = []
    /// How many files were over the size threshold, before the cap on the list.
    public var matches = 0
    /// True when more files matched than the list holds.
    public var truncated: Bool { matches > items.count }
    /// True when the walk hit its entry cap before finishing. The list is then
    /// incomplete and the UI must say so.
    public var capped = false
    /// The folders whose share of the walk ran out, so the notice can name
    /// exactly what was not fully read.
    public var cappedFolders: [String] = []
    public var visited = 0
    /// Over the size threshold but changed in the last minute, so probably
    /// still being written.
    public var skippedRecent = 0
    public var cancelled = false
}

public struct LargeFileTrashResult: Sendable {
    public var moved = 0
    public var bytes: UInt64 = 0
    /// Paths that went to the Trash, so the list can drop exactly those.
    public var movedPaths: [String] = []
    /// Changed since the scan, or modified in the last minute.
    public var skippedRecent: [String] = []
    /// Failed the last-moment safety check (outside the roots, a symlink, a
    /// folder, or inside a bundle).
    public var refused: [String] = []
    /// The Trash call itself threw: in use, or not permitted.
    public var failed: [String] = []
}

public enum LargeFileVerdict: Sendable, Equatable {
    case ok
    case tooRecent
    case refused(String)
}

public enum LargeFileSort: String, CaseIterable, Identifiable, Sendable {
    case size, age, name
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .size: return "Largest first"
        case .age:  return "Oldest first"
        case .name: return "Name"
        }
    }
}

// MARK: - Scan

public enum LargeFileScan {

    /// A file changed less than this long ago is left alone: it may still be
    /// downloading, exporting or being saved.
    public static let recentWindow: TimeInterval = 60

    public static let defaultLimit = 200
    public static let defaultMaxEntries = 400_000

    /// Folders that hold their contents as one unit. A big file inside one is
    /// part of that app or library, not a file you can judge on its own, so the
    /// whole folder is treated as a single opaque item and skipped.
    ///
    /// The enumerator also skips what Launch Services knows to be a package,
    /// but that list depends on what is installed, so the common ones are named.
    static let bundleExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc",
        "photoslibrary", "musiclibrary", "imovielibrary", "tvlibrary", "fcpbundle",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "dsym",
        "sparsebundle", "vmwarevm", "pvm", "utm", "pkg", "logicx", "band", "rtfd",
    ]

    static func isBundleName(_ name: String) -> Bool {
        bundleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Where Music and TV keep their media when the library is a plain folder
    /// rather than a package. Removing a track from here leaves the app
    /// showing it as missing, so these are never listed.
    static let appLibraryFolders: Set<String> = ["Media.localized", "iTunes Media"]

    /// A folder the scan treats as one opaque item.
    static func isOpaqueFolder(_ name: String) -> Bool {
        isBundleName(name) || appLibraryFolders.contains(name)
    }

    private static var fm: FileManager { .default }

    // MARK: - Roots

    /// The folders that hold your own files, in the order they are scanned.
    static let defaultRootNames = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]

    /// Where to look: the six personal folders that exist, in full, and the
    /// files directly in the home folder. Resolved and de-duplicated.
    ///
    /// Nothing under `Library`, `/Applications`, `/System` or `/Volumes` is
    /// ever returned, even if one of the personal folders is a link into it.
    public static func roots(home: URL? = nil) -> LargeFileRoots {
        let h = home ?? fm.homeDirectoryForCurrentUser
        var seen = Set<String>()
        var deep: [URL] = []
        for name in defaultRootNames {
            let c = h.appending(path: name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let r = ProjectScan.canonical(c)
            guard isAcceptableRoot(r, home: h) else { continue }
            if seen.insert(r.path).inserted { deep.append(r) }
        }
        let top = ProjectScan.canonical(h)
        let shallow = isAcceptableHome(top) ? [top] : []
        return LargeFileRoots(deep: deep, shallow: shallow)
    }

    /// The Projects rules (no home folder, no `Library`, no system folders),
    /// plus no other volume: a personal folder that is really a link to an
    /// external disk is not scanned.
    public static func isAcceptableRoot(_ url: URL, home: URL? = nil) -> Bool {
        guard ProjectScan.isAcceptableRoot(url, home: home) else { return false }
        let canonical = ProjectScan.canonical(url)
        let parts = canonical.pathComponents
        if parts.count > 1, parts[1] == "Volumes" { return false }
        // A personal folder that is really a link somewhere else, such as
        // another user's folder or /private/tmp, is not scanned. It has to
        // resolve to somewhere inside your home folder.
        let h = ProjectScan.canonical(home ?? fm.homeDirectoryForCurrentUser)
        return ProjectScan.isInside(canonical, of: h)
    }

    private static func isAcceptableHome(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard parts.count > 1 else { return false }
        return !["Volumes", "System", "Library", "Applications"].contains(parts[1])
    }

    // MARK: - Scanning

    /// Finds the biggest files under `roots` that are at least `minBytes`.
    /// Slow on a big tree: call it off the main actor. Cancellation is
    /// cooperative through `isCancelled`.
    ///
    /// Hidden files and folders are skipped. So is the inside of every bundle,
    /// and every symlink is ignored rather than followed, so a link into a big
    /// tree elsewhere is neither counted nor entered. `maxEntries` bounds the
    /// walk so a root pointed at something enormous cannot hang the app; it
    /// sets `capped`. `limit` bounds the list; `matches` says how many there
    /// were in all.
    public static func scan(
        roots: LargeFileRoots,
        minBytes: UInt64,
        now: Date = Date(),
        limit: Int = defaultLimit,
        maxEntries: Int = defaultMaxEntries,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> LargeFileScanResult {
        var result = LargeFileScanResult()
        var found: [LargeFileItem] = []
        var seen = Set<String>()
        var visited = 0

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]
        let keySet = Set(keys)

        // Resolved once, so every path found below is spelled the way
        // `verify` will later spell it.
        let walks: [(root: URL, shallow: Bool)] =
            roots.deep.map { (ProjectScan.canonical($0), false) }
            + roots.shallow.map { (ProjectScan.canonical($0), true) }

        for (index, walkRoot) in walks.enumerated() {
            let (root, shallow) = walkRoot
            if isCancelled() { result.cancelled = true; return result }
            // Each folder gets an equal share of what is left, and a folder
            // that uses less hands the rest on. One huge Documents tree cannot
            // starve Movies, Music and Pictures.
            let budget = max(1, (maxEntries - visited) / (walks.count - index))
            var rootVisited = 0
            guard let e = fm.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in e {
                visited += 1
                rootVisited += 1
                if visited % 256 == 0, isCancelled() { result.cancelled = true; return result }
                if rootVisited > budget {
                    result.capped = true
                    result.cappedFolders.append(root.lastPathComponent)
                    break
                }

                guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
                if v.isSymbolicLink == true { e.skipDescendants(); continue }

                let name = url.lastPathComponent
                if name.hasPrefix(".") {
                    if v.isDirectory == true { e.skipDescendants() }
                    continue
                }
                if v.isDirectory == true {
                    // A bundle is one opaque item, and a shallow root never
                    // goes below its top level.
                    if shallow || v.isPackage == true || isOpaqueFolder(name) { e.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true else { continue }

                let bytes = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                guard bytes >= max(minBytes, 1) else { continue }
                guard let modified = v.contentModificationDate else { continue }
                // A date in the future counts as recent: a wrong clock is a
                // reason to leave it alone.
                if now.timeIntervalSince(modified) < recentWindow {
                    result.skippedRecent += 1
                    continue
                }
                guard seen.insert(url.path).inserted else { continue }
                found.append(LargeFileItem(url: url, bytes: bytes,
                                           lastAccessed: v.contentAccessDate, lastModified: modified))
            }
        }
        result.visited = visited
        result.matches = found.count
        result.items = Array(sorted(found, by: .size).prefix(max(0, limit)))
        return result
    }

    // MARK: - Ordering and wording

    public static func sorted(_ items: [LargeFileItem], by sort: LargeFileSort) -> [LargeFileItem] {
        switch sort {
        case .size:
            return items.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
        case .age:
            // Longest unused first. A file with no known date goes last: it is
            // not known to be old.
            return items.sorted { a, b in
                switch (a.lastUsed, b.lastUsed) {
                case let (x?, y?): return x != y ? x < y : a.url.path < b.url.path
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return a.url.path < b.url.path
                }
            }
        case .name:
            return items.sorted {
                let c = $0.name.localizedStandardCompare($1.name)
                return c != .orderedSame ? c == .orderedAscending : $0.url.path < $1.url.path
            }
        }
    }

    /// "Not opened for 8 months", or "Modified 8 months ago" when there is no
    /// access date to go on. The access date is only a hint (a backup or an
    /// indexer can touch it), so the wording stays plain.
    public static func ageText(for item: LargeFileItem, now: Date = Date()) -> String {
        guard let used = item.lastUsed else { return "Date unknown" }
        let days = max(0, Int(now.timeIntervalSince(used) / 86_400))
        if item.lastAccessed != nil {
            if days < 1 { return "Opened today" }
            return "Not opened for " + span(days: days)
        }
        if days < 1 { return "Modified today" }
        return "Modified " + span(days: days) + " ago"
    }

    static func span(days: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if days < 60 { return unit(days, "day") }
        if days < 730 { return unit(days / 30, "month") }
        return unit(days / 365, "year")
    }

    // MARK: - Moving to the Trash

    /// Whether `url` sits where the scan could have found it: strictly inside a
    /// deep root, or directly inside a shallow one. Whole path components, so
    /// `/a/proj-evil` is not inside `/a/proj`.
    static func rootContaining(_ url: URL, in roots: LargeFileRoots) -> (root: URL, shallow: Bool)? {
        for r in roots.deep.map(ProjectScan.canonical) where ProjectScan.isInside(url, of: r) {
            return (r, false)
        }
        let parent = url.deletingLastPathComponent()
        for r in roots.shallow.map(ProjectScan.canonical) where parent.pathComponents == r.pathComponents {
            return (r, true)
        }
        return nil
    }

    /// The last line of defence, run on every item immediately before it moves.
    ///
    /// The list was built minutes ago. In that time a symlink can replace the
    /// file, a folder can take its name, or the file can be rewritten. So
    /// everything is decided again against what is on disk now: the path must
    /// resolve to itself (no symlink anywhere in it), still be a regular file,
    /// sit inside a scan root with no hidden or bundle folder on the way, be
    /// unchanged since the scan, and not have changed in the last minute.
    public static func verify(_ item: LargeFileItem, roots: LargeFileRoots,
                              now: Date = Date()) -> LargeFileVerdict {
        let given = URL(fileURLWithPath: item.url.path)
        guard !given.pathComponents.contains("..") else { return .refused("odd path") }

        // The link itself, not what it points at: resource values on a symlink
        // describe the link.
        guard let v = try? given.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey,
        ]) else { return .refused("no longer there") }
        if v.isSymbolicLink == true { return .refused("a symlink") }
        if v.isDirectory == true { return .refused("a folder, not a file") }
        guard v.isRegularFile == true else { return .refused("not a regular file") }

        // If any part of the path is now a symlink, the real path differs from
        // the one the scan recorded, and the file is not what was listed.
        let resolved = ProjectScan.canonical(given)
        guard resolved.path == given.path else { return .refused("a symlink is involved") }

        guard let (root, _) = rootContaining(resolved, in: roots) else {
            return .refused("outside the folders being scanned")
        }
        let below = Array(resolved.pathComponents.dropFirst(root.pathComponents.count))
        if below.contains(where: { $0.hasPrefix(".") }) { return .refused("hidden") }
        if below.dropLast().contains(where: isOpaqueFolder) { return .refused("inside a bundle or media library") }

        guard let modified = v.contentModificationDate else { return .refused("no date") }
        if now.timeIntervalSince(modified) < recentWindow { return .tooRecent }
        // Not the file that was listed: someone saved over it since.
        if let listed = item.lastModified, abs(listed.timeIntervalSince(modified)) > 1 { return .tooRecent }
        return .ok
    }

    /// The real Trash call. Reversible: the file lands in the Trash with
    /// "Put Back" available. Never `removeItem`.
    public static func trashItem(_ url: URL) throws {
        try fm.trashItem(at: url, resultingItemURL: nil)
    }

    /// Moves each verified file to the Trash. `trash` is injectable so tests do
    /// not fill the real Trash.
    public static func moveToTrash(
        _ items: [LargeFileItem], roots: LargeFileRoots, now: Date = Date(),
        trash: (URL) throws -> Void = LargeFileScan.trashItem
    ) -> LargeFileTrashResult {
        var out = LargeFileTrashResult()
        for item in items {
            switch verify(item, roots: roots, now: now) {
            case .refused:
                out.refused.append(item.url.path)
            case .tooRecent:
                out.skippedRecent.append(item.url.path)
            case .ok:
                do {
                    try trash(item.url)
                    out.moved += 1
                    out.bytes += item.bytes
                    out.movedPaths.append(item.url.path)
                } catch {
                    out.failed.append(item.url.path)
                }
            }
        }
        return out
    }
}
