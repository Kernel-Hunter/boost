import Foundation

// MARK: - What counts as a rebuildable project folder

/// The kinds of folder the Projects tab will offer to move to the Trash.
///
/// The Disk tab refuses `node_modules` outright, because there it would be a
/// guess: a folder with that name might be anything. Here it is allowed only
/// when a manifest sitting next to it proves what it is, the user has opted in
/// by opening the tab, and nothing is deleted. Everything goes to the Trash.
public enum ProjectKind: String, Sendable, CaseIterable {
    case node, swiftPM, cargo, cocoaPods, gradle, python, next, nuxt

    public var label: String {
        switch self {
        case .node:      "node_modules"
        case .swiftPM:   "SwiftPM build"
        case .cargo:     "Rust target"
        case .cocoaPods: "CocoaPods"
        case .gradle:    "Gradle build"
        case .python:    "Python venv"
        case .next:      "Next.js build"
        case .nuxt:      "Nuxt build"
        }
    }

    /// What brings it back. Shown on every row so the decision is informed.
    public var regeneration: String {
        switch self {
        case .node:
            "npm, yarn or pnpm install rebuilds it. With pnpm some files are shared "
            + "with its store, so less space comes back."
        case .swiftPM:   "swift build rebuilds it."
        case .cargo:     "cargo build rebuilds it."
        case .cocoaPods: "pod install rebuilds it."
        case .gradle:    "./gradlew build rebuilds it."
        case .python:
            "python3 -m venv and pip install rebuild it, but only if your dependencies "
            + "are listed in requirements.txt or pyproject.toml."
        case .next:      "next build or next dev rebuilds it."
        case .nuxt:      "nuxt build or nuxt dev rebuilds it."
        }
    }
}

/// One row in the Projects list.
public struct ProjectItem: Identifiable, Sendable, Equatable {
    /// The folder's path, which is unique and stable across rescans.
    public var id: String { url.path }
    /// The folder that would be moved, for example `…/app/node_modules`.
    public let url: URL
    public let kind: ProjectKind
    public let bytes: UInt64
    /// True when sizing stopped at the entry cap, so `bytes` is a floor.
    public let sizeCapped: Bool
    public let lastActive: Date
    public let idleDays: Int

    /// The folder that holds the manifest. Its name is the project's name.
    public var projectURL: URL { url.deletingLastPathComponent() }
    public var projectName: String { projectURL.lastPathComponent }
}

public struct ProjectScanResult: Sendable {
    public var items: [ProjectItem] = []
    /// True when the walk hit its entry cap before finishing, or sizing did.
    /// The list is then incomplete and the UI must say so.
    public var capped = false
    public var visited = 0
    /// Matched and old enough, but changed in the last 24 hours.
    public var skippedRecent = 0
    public var cancelled = false
}

public struct ProjectTrashResult: Sendable {
    public var moved = 0
    public var bytes: UInt64 = 0
    /// Changed since the scan, or modified in the last 24 hours.
    public var skippedRecent: [String] = []
    /// Failed the last-moment safety check (outside the roots, a symlink, or
    /// no longer matching its rule).
    public var refused: [String] = []
    /// The Trash call itself threw: in use, or not permitted.
    public var failed: [String] = []
}

public enum ProjectVerdict: Sendable, Equatable {
    case ok
    case tooRecent
    case refused(String)
}

public enum ProjectScan {

    // MARK: - Rules

    private struct Rule {
        let kind: ProjectKind
        let folders: [String]
        /// Any one of these next to the folder proves it. Empty for a virtualenv,
        /// which is proven by what is inside it.
        let siblings: [String]
        /// A file that must exist inside the folder.
        let marker: String?
    }

    private static let rules: [Rule] = [
        Rule(kind: .node,      folders: ["node_modules"], siblings: ["package.json"], marker: nil),
        Rule(kind: .swiftPM,   folders: [".build"],       siblings: ["Package.swift"], marker: nil),
        Rule(kind: .cargo,     folders: ["target"],       siblings: ["Cargo.toml"], marker: nil),
        Rule(kind: .cocoaPods, folders: ["Pods"],         siblings: ["Podfile"], marker: nil),
        Rule(kind: .gradle,    folders: ["build"],        siblings: ["build.gradle", "build.gradle.kts"], marker: nil),
        Rule(kind: .python,    folders: [".venv", "venv"], siblings: [], marker: "pyvenv.cfg"),
        Rule(kind: .next,      folders: [".next"],        siblings: ["package.json"], marker: nil),
        Rule(kind: .nuxt,      folders: [".nuxt"],        siblings: ["package.json"], marker: nil),
    ]

    /// Files whose age says a virtualenv's project is still being worked on.
    private static let pythonProjectFiles = [
        "pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "poetry.lock",
    ]

    /// Deepest folder we will report, counted in path components below a root.
    public static let maxDepth = 6
    public static let recentWindow: TimeInterval = 24 * 3600

    private static var fm: FileManager { .default }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// What this folder is, if a manifest proves it. `nil` for a folder that
    /// merely has the right name: a `node_modules` with no `package.json`
    /// beside it could be anything, so it is not ours to touch.
    ///
    /// Returns the files whose age describes the project.
    static func match(_ folder: URL) -> (kind: ProjectKind, ageFiles: [URL])? {
        let name = folder.lastPathComponent
        guard let rule = rules.first(where: { $0.folders.contains(name) }) else { return nil }
        let parent = folder.deletingLastPathComponent()

        if let marker = rule.marker {
            let m = folder.appending(path: marker)
            guard isRegularFile(m) else { return nil }
            let siblings = pythonProjectFiles.map { parent.appending(path: $0) }.filter(isRegularFile)
            return (rule.kind, siblings.isEmpty ? [m] : siblings)
        }
        let present = rule.siblings.map { parent.appending(path: $0) }.filter(isRegularFile)
        return present.isEmpty ? nil : (rule.kind, present)
    }

    // MARK: - Paths

    /// The real path, every symlink resolved, via `realpath(3)`.
    ///
    /// Not `URL.resolvingSymlinksInPath()`: that special-cases `/private`, so
    /// `/var/folders/…` and `/private/var/folders/…` come out differently
    /// depending on whether the path existed yet. The safety check compares two
    /// spellings of one path, and they must agree on what the real one is.
    /// A path that does not exist cannot be resolved and comes back tidied only.
    static func canonical(_ url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buffer) != nil {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
        }
        return url.standardizedFileURL
    }

    // MARK: - Roots

    /// Where developers keep code. Deliberately not Documents, Desktop,
    /// Downloads or Library: reading those raises macOS privacy prompts, and
    /// this app promises it reads no personal data.
    static let defaultRootNames = [
        "Developer", "Projects", "dev", "code", "src", "Sites", "workspace", "repos",
    ]

    /// Folders in your home folder that are plainly a project: a git repository
    /// or a package manifest at the top. Listing the home folder raises no
    /// privacy prompt; the private folders are skipped by name and never opened.
    static let privateHomeFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
        "Pictures", "Public", "Applications",
    ]

    static func homeProjectFolders(home: URL) -> [URL] {
        guard let kids = try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let markers = [".git", "package.json", "Package.swift", "Cargo.toml", "Podfile"]
        return kids.filter { kid in
            guard !privateHomeFolders.contains(kid.lastPathComponent),
                  (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            return markers.contains { fm.fileExists(atPath: kid.appending(path: $0).path) }
        }
    }

    /// The folders to scan: the defaults that exist, plus the ones the user
    /// added. Resolved and de-duplicated, so a root listed twice, or reached
    /// through a symlink, is walked once.
    public static func roots(extra: [String] = [], home: URL? = nil) -> [URL] {
        let h = home ?? fm.homeDirectoryForCurrentUser
        var candidates = defaultRootNames.map { h.appending(path: $0) }
        candidates += homeProjectFolders(home: h)
        candidates += extra.map { URL(fileURLWithPath: $0) }

        var seen = Set<String>()
        var out: [URL] = []
        for c in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let r = canonical(c)
            guard isAcceptableRoot(r, home: h) else { continue }
            if seen.insert(r.path).inserted { out.append(r) }
        }
        return out
    }

    /// Refuses roots that would make a scan wander somewhere it should not:
    /// the home folder itself (it contains Library), the filesystem root, and
    /// system locations. Anything else the user picked on purpose.
    public static func isAcceptableRoot(_ url: URL, home: URL? = nil) -> Bool {
        let h = canonical(home ?? fm.homeDirectoryForCurrentUser)
        let r = canonical(url)
        let parts = r.pathComponents
        guard parts.count > 1 else { return false }                  // "/"
        if r.path == h.path { return false }
        let library = h.appending(path: "Library")
        if r.path == library.path || isInside(r, of: library) { return false }
        // Applications and Library as top-level folders: system, not projects.
        let forbidden = ["System", "usr", "bin", "sbin", "Library", "Applications", "etc", "dev", "opt"]
        if parts.count > 1, forbidden.contains(parts[1]) { return false }
        return true
    }

    /// True when `url` is strictly below `root`, compared by whole path
    /// components. A string prefix would treat `/a/proj-evil` as inside `/a/proj`.
    static func isInside(_ url: URL, of root: URL) -> Bool {
        let u = url.pathComponents, r = root.pathComponents
        return u.count > r.count && Array(u.prefix(r.count)) == r
    }

    // MARK: - Age

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The newest sign of life in the project: its manifest, or the git index
    /// (which every commit, pull and checkout rewrites).
    ///
    /// The index is looked up from the project folder upward to the scan root,
    /// not only beside the manifest. In a monorepo the `.git` lives at the top
    /// and a package's `package.json` can sit untouched for a year while the
    /// repo is committed to daily; judging by the manifest alone would list a
    /// live project as abandoned.
    static func lastActivity(ageFiles: [URL], project: URL, root: URL) -> Date? {
        var newest = ageFiles.compactMap(modified).max()
        var dir = project.standardizedFileURL
        let top = root.standardizedFileURL
        while dir.path == top.path || isInside(dir, of: top) {
            if let d = modified(dir.appending(path: ".git/index")) {
                newest = max(newest ?? d, d)
                break
            }
            if dir.path == top.path { break }
            dir = dir.deletingLastPathComponent()
        }
        return newest
    }

    /// True when the folder, or anything directly inside it, changed in the
    /// last 24 hours. A fresh `npm install` or a build in progress shows up
    /// here even when the manifest is old. A date in the future counts as
    /// recent: a wrong clock is a reason to leave it alone.
    static func recentlyModified(_ folder: URL, now: Date, childCap: Int = 5000) -> Bool {
        let cutoff = now.addingTimeInterval(-recentWindow)
        if let d = modified(folder), d > cutoff { return true }
        guard let children = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return false }
        for child in children.prefix(childCap) {
            if let d = modified(child), d > cutoff { return true }
        }
        return false
    }

    // MARK: - Measuring

    /// Allocated size of everything under `folder`, counting hidden files
    /// (`node_modules/.bin` is real space) and never following symlinks, so a
    /// link into a large tree elsewhere is not counted as this folder's.
    static func size(of folder: URL, entryCap: Int, isCancelled: @Sendable () -> Bool)
        -> (bytes: UInt64, capped: Bool, cancelled: Bool)
    {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: []) else {
            return (0, false, false)
        }
        var total: UInt64 = 0
        var n = 0
        for case let child as URL in e {
            n += 1
            if n % 256 == 0, isCancelled() { return (total, false, true) }
            if n > entryCap { return (total, true, false) }
            guard let v = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return (total, false, false)
    }

    // MARK: - Scanning

    private struct Found {
        let folder: URL
        let kind: ProjectKind
        let ageFiles: [URL]
        let root: URL
    }

    /// Finds rebuildable folders under `roots` whose project has been untouched
    /// for at least `olderThanDays`. Slow on a big tree: call it off the main
    /// actor. Cancellation is cooperative through `isCancelled`.
    ///
    /// `maxEntries` bounds the directory walk so a root pointed at something
    /// enormous cannot hang the app; `sizeEntryCap` bounds each folder's sizing.
    /// Either limit sets `capped`.
    public static func scan(
        roots: [URL],
        olderThanDays: Int,
        now: Date = Date(),
        maxEntries: Int = 200_000,
        sizeEntryCap: Int = 1_500_000,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ProjectScanResult {
        var result = ProjectScanResult()
        var found: [Found] = []
        var seen = Set<String>()
        var visited = 0

        // Resolved once, so every path found below is spelled the way
        // `verify` will later spell it.
        let resolvedRoots = roots.map(canonical)

        walk: for root in resolvedRoots {
            var stack: [(URL, Int)] = [(root, 0)]
            while let (dir, depth) = stack.popLast() {
                if isCancelled() { result.cancelled = true; return result }
                guard let children = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
                ) else { continue }

                visited += children.count
                if visited > maxEntries { result.capped = true; break walk }

                for child in children {
                    guard let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          v.isSymbolicLink != true, v.isDirectory == true else { continue }
                    let childDepth = depth + 1

                    if let m = match(child) {
                        // A matched folder is never descended into, so a
                        // dependency's own node_modules is not counted twice.
                        if childDepth <= maxDepth, seen.insert(child.path).inserted {
                            found.append(Found(folder: child, kind: m.kind, ageFiles: m.ageFiles, root: root))
                        }
                        continue
                    }
                    let name = child.lastPathComponent
                    // Hidden folders (.git, .cache, .idea) are never projects,
                    // and a node_modules without a manifest is not ours: neither
                    // is worth walking.
                    if name.hasPrefix(".") || name == "node_modules" { continue }
                    if childDepth < maxDepth { stack.append((child, childDepth)) }
                }
            }
        }
        result.visited = visited

        var items: [ProjectItem] = []
        for f in found {
            if isCancelled() { result.cancelled = true; return result }
            let project = f.folder.deletingLastPathComponent()
            guard let active = lastActivity(ageFiles: f.ageFiles, project: project, root: f.root) else { continue }
            let days = idleDays(since: active, now: now)
            guard days >= olderThanDays else { continue }
            if recentlyModified(f.folder, now: now) { result.skippedRecent += 1; continue }

            let s = size(of: f.folder, entryCap: sizeEntryCap, isCancelled: isCancelled)
            if s.cancelled { result.cancelled = true; return result }
            if s.capped { result.capped = true }
            guard s.bytes > 0 else { continue }
            items.append(ProjectItem(url: f.folder, kind: f.kind, bytes: s.bytes, sizeCapped: s.capped,
                                     lastActive: active, idleDays: days))
        }
        result.items = items.sorted { $0.bytes > $1.bytes }
        return result
    }

    static func idleDays(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    // MARK: - Moving to the Trash

    /// The last line of defence, run on every item immediately before it moves.
    ///
    /// The list was built minutes ago. In that time a symlink can replace the
    /// folder, the folder can be renamed, or the project can come back to life.
    /// So everything is decided again against what is on disk now: the path must
    /// resolve to itself (no symlink anywhere in it), sit strictly inside a scan
    /// root, still match its manifest rule as the same kind, still be older than
    /// the cutoff, and not have changed in the last 24 hours.
    public static func verify(_ item: ProjectItem, roots: [URL], olderThanDays: Int,
                              now: Date = Date()) -> ProjectVerdict {
        let given = URL(fileURLWithPath: item.url.path)
        guard !given.pathComponents.contains("..") else { return .refused("odd path") }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: given.path, isDirectory: &isDir), isDir.boolValue else {
            return .refused("no longer there")
        }
        // If any part of the path is now a symlink, the real path differs from
        // the one the scan recorded, and the folder is not what was listed.
        let resolved = canonical(given)
        guard resolved.path == given.path else {
            return .refused("a symlink is involved")
        }

        let rootsResolved = roots.map(canonical)
        guard let root = rootsResolved.first(where: { isInside(resolved, of: $0) }) else {
            return .refused("outside the folders being scanned")
        }
        guard let m = match(resolved), m.kind == item.kind else {
            return .refused("its manifest is gone")
        }

        if let active = lastActivity(ageFiles: m.ageFiles, project: resolved.deletingLastPathComponent(), root: root),
           idleDays(since: active, now: now) < olderThanDays {
            return .tooRecent
        }
        if recentlyModified(resolved, now: now) { return .tooRecent }
        return .ok
    }

    /// The real Trash call. Reversible: the folder lands in the Trash with
    /// "Put Back" available. Never `removeItem`.
    public static func trashItem(_ url: URL) throws {
        try fm.trashItem(at: url, resultingItemURL: nil)
    }

    /// Moves each verified item to the Trash. `trash` is injectable so tests do
    /// not fill the real Trash.
    public static func moveToTrash(
        _ items: [ProjectItem], roots: [URL], olderThanDays: Int, now: Date = Date(),
        trash: (URL) throws -> Void = ProjectScan.trashItem
    ) -> ProjectTrashResult {
        var out = ProjectTrashResult()
        for item in items {
            switch verify(item, roots: roots, olderThanDays: olderThanDays, now: now) {
            case .refused:
                out.refused.append(item.url.path)
            case .tooRecent:
                out.skippedRecent.append(item.url.path)
            case .ok:
                do {
                    try trash(item.url)
                    out.moved += 1
                    out.bytes += item.bytes
                } catch {
                    out.failed.append(item.url.path)
                }
            }
        }
        return out
    }
}
