import Foundation
import CoreServices

// MARK: - Models

/// An app bundle found in /Applications or ~/Applications.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// The name Finder shows, which is also the name leftovers are matched on.
    public let name: String
    /// Every exact name this app goes by on disk: the file name, plus
    /// CFBundleName when it differs ("Visual Studio Code" keeps its data under
    /// "Code"). Both are the app's own names, so matching them exactly is not
    /// fuzzy.
    public let matchNames: [String]
    public let bundleID: String?
    public let version: String?
    /// From Spotlight. Nil when indexing is off or the app was never opened,
    /// and shown as unknown rather than guessed.
    public let lastUsed: Date?
    /// Nil until measured. Sizing every bundle takes seconds, so the list is
    /// shown first and the sizes arrive afterwards.
    public var bytes: UInt64?
}

/// A file or folder an app left behind in the user's Library.
public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// Which Library folder it sits in, for display.
    public let kind: String
    public var bytes: UInt64
    public var name: String { url.lastPathComponent }
}

public struct LeftoverScan: Sendable {
    public var found: [Leftover] = []
    /// Matching names that were not listed because they are symlinks or sit
    /// behind one. Counted so the screen can say so instead of hiding them.
    public var ignored: [String] = []
}

/// Why an app may not be uninstalled from here.
public enum Refusal: Equatable, Sendable {
    case apple, boost, outsideApplications, running

    public func message(for name: String) -> String {
        switch self {
        case .apple:
            return "\(name) is part of macOS or made by Apple. Boost will not remove it."
        case .boost:
            return "This is Boost. It cannot remove itself while it is running."
        case .outsideApplications:
            return "\(name) is not in /Applications or ~/Applications, so Boost will not touch it."
        case .running:
            return "\(name) is running. Quit it first, then check again. Boost never quits apps for you here."
        }
    }
}

/// Which apps are open right now, as bundle ids and resolved bundle paths.
public struct RunningApps: Sendable {
    public var ids: Set<String>
    public var paths: Set<String>
    public init(ids: Set<String> = [], paths: Set<String> = []) {
        self.ids = ids
        self.paths = paths
    }
    public static let none = RunningApps()
}

public enum AppSort: String, CaseIterable, Identifiable, Sendable {
    case name, size, lastUsed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .lastUsed: return "Last used"
        }
    }
    /// The direction people mean by default: A to Z, biggest first, and
    /// longest unused first, since that is the one you uninstall from.
    public var defaultAscending: Bool { self != .size }
}

public struct MovedItem: Equatable, Sendable {
    public let original: URL
    public let trashed: URL
    public let bytes: UInt64
}

public struct SkippedItem: Equatable, Sendable {
    public let path: String
    public let reason: String
}

public struct TrashOutcome: Sendable {
    public var moved: [MovedItem] = []
    public var skipped: [SkippedItem] = []
    public var bytes: UInt64 { moved.reduce(0) { $0 + $1.bytes } }
}

/// Moves one item to the Trash and returns where it ended up. Injected so the
/// tests can watch what would be moved without filling the real Trash.
public typealias TrashMover = @Sendable (URL) throws -> URL

// MARK: - Where leftovers live

/// The Library folders searched, and the exact names looked for in each.
///
/// Nothing here is a substring or prefix match on a name, with one narrow
/// exception: launch agent and preference plists, which are named
/// `<bundle id>.<something>.plist` by design. Those still have to start with
/// the full id and a dot. A looser rule is how "Slack" ends up taking "Slack
/// Helper" with it.
enum LeftoverLocation: CaseIterable {
    case applicationSupport, caches, preferences, containers, groupContainers
    case savedState, logs, httpStorages, webKit, launchAgents

    var folder: String {
        switch self {
        case .applicationSupport: return "Application Support"
        case .caches:             return "Caches"
        case .preferences:        return "Preferences"
        case .containers:         return "Containers"
        case .groupContainers:    return "Group Containers"
        case .savedState:         return "Saved Application State"
        case .logs:               return "Logs"
        case .httpStorages:       return "HTTPStorages"
        case .webKit:             return "WebKit"
        case .launchAgents:       return "LaunchAgents"
        }
    }

    /// Names we can state outright. Preferences and launch agents are matched
    /// by pattern instead, so they return nothing here.
    func exactNames(for app: InstalledApp) -> [String] {
        let id = app.bundleID.flatMap { AppScan.isPlainComponent($0) ? $0 : nil }
        let names = app.matchNames.filter(AppScan.isPlainComponent)
        switch self {
        case .applicationSupport: return (id.map { [$0] } ?? []) + names
        case .caches, .containers, .httpStorages, .webKit: return id.map { [$0] } ?? []
        // "group.<id>" is the one shape of group container that names its
        // owner. The Team-ID-prefixed form is not matched: there is no way to
        // know from here that it belongs to this app and not a sibling.
        case .groupContainers:    return id.map { [$0, "group." + $0] } ?? []
        case .savedState:         return id.map { [$0 + ".savedState"] } ?? []
        case .logs:               return names
        case .preferences, .launchAgents: return []
        }
    }

    var usesPattern: Bool { self == .preferences || self == .launchAgents }

    func matches(_ name: String, for app: InstalledApp, otherBundleIDs: Set<String>) -> Bool {
        if usesPattern {
            guard let id = app.bundleID, AppScan.isPlainComponent(id) else { return false }
            return AppScan.plist(name, belongsTo: id, otherBundleIDs: otherBundleIDs)
        }
        return exactNames(for: app).contains(name)
    }
}

// MARK: - Discovery, safety, removal

public enum AppScan {

    static let boostBundleID = "boost.local.app"

    // MARK: Discovery

    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
    }

    /// Reads an app bundle's identity. Returns nil for anything that is not a
    /// readable bundle, so a stray folder named `Foo.app` is not offered.
    public static func readApp(at url: URL) -> InstalledApp? {
        guard url.pathExtension == "app",
              let info = Bundle(url: url)?.infoDictionary, !info.isEmpty else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        var names = [fileName]
        if let n = info["CFBundleName"] as? String, n != fileName { names.append(n) }
        return InstalledApp(
            url: url,
            name: fileName,
            matchNames: names,
            bundleID: info["CFBundleIdentifier"] as? String,
            version: info["CFBundleShortVersionString"] as? String,
            lastUsed: lastUsed(of: url),
            bytes: nil)
    }

    /// kMDItemLastUsedDate is public Spotlight metadata, the same field Finder's
    /// "Date Last Opened" shows.
    static func lastUsed(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// One level of each root only. Utilities in subfolders are skipped on
    /// purpose: they are mostly Apple's, and walking deeper finds installers
    /// and helper bundles that are not apps a person chose.
    public static func discoverApps(in roots: [URL]) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
            for url in entries where url.pathExtension == "app" {
                // ~/Applications is sometimes a symlink to /Applications.
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted,
                      let app = readApp(at: url) else { continue }
                apps.append(app)
            }
        }
        return apps
    }

    // MARK: List helpers

    public static func visible(_ apps: [InstalledApp], query: String,
                               sort: AppSort, ascending: Bool) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.bundleID?.localizedCaseInsensitiveContains(q) ?? false)
        }
        func byName(_ a: InstalledApp, _ b: InstalledApp) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        // Unknown values go last in either direction: "never opened" is not
        // older than anything, it is just not known.
        func ordered<T: Comparable>(_ a: T?, _ b: T?, _ x: InstalledApp, _ y: InstalledApp) -> Bool {
            switch (a, b) {
            case let (l?, r?): return l == r ? byName(x, y) : (ascending ? l < r : l > r)
            case (nil, nil):   return byName(x, y)
            case (_?, nil):    return true
            case (nil, _?):    return false
            }
        }
        switch sort {
        case .name:
            return filtered.sorted { ascending ? byName($0, $1) : byName($1, $0) }
        case .size:
            return filtered.sorted { ordered($0.bytes, $1.bytes, $0, $1) }
        case .lastUsed:
            return filtered.sorted { ordered($0.lastUsed, $1.lastUsed, $0, $1) }
        }
    }

    // MARK: Refusal

    /// Why this app must not be removed from here, or nil when it may be.
    ///
    /// Checked when an app is picked and again immediately before anything
    /// moves, because an app can be opened in between.
    public static func refusal(for app: InstalledApp, appRoots: [URL],
                               running: RunningApps) -> Refusal? {
        let id = app.bundleID ?? ""
        if id.lowercased().hasPrefix("com.apple.") { return .apple }
        if id == boostBundleID { return .boost }
        if !isTrashableApp(app.url, appRoots: appRoots) { return .outsideApplications }
        let resolved = app.url.standardizedFileURL.resolvingSymlinksInPath().path
        if running.paths.contains(resolved) || (!id.isEmpty && running.ids.contains(id)) {
            return .running
        }
        return nil
    }

    /// True when `url` is an `.app` that really sits inside one of the roots.
    /// Judged on the resolved path, so an entry in /Applications that is a
    /// link to somewhere else is refused rather than followed.
    public static func isTrashableApp(_ url: URL, appRoots: [URL]) -> Bool {
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        guard !isLink else { return false }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension == "app",
              resolved.lastPathComponent == url.lastPathComponent else { return false }
        let parts = resolved.pathComponents
        guard !parts.contains("..") else { return false }
        return appRoots.contains { root in
            let r = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            return parts.count > r.count && Array(parts.prefix(r.count)) == r
        }
    }

    // MARK: Leftovers

    static func isPlainComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0")
    }

    /// `<id>.plist` or `<id>.<something>.plist`, never a name that merely starts
    /// with the same letters.
    ///
    /// The exclusion exists because bundle ids nest: `com.google.Chrome` is a
    /// prefix of `com.google.Chrome.canary`, a different app with its own
    /// preferences. If another installed app owns the longer id, its file is
    /// not ours.
    static func plist(_ name: String, belongsTo id: String, otherBundleIDs: Set<String>) -> Bool {
        let suffix = ".plist"
        guard name.hasSuffix(suffix) else { return false }
        let stem = String(name.dropLast(suffix.count))
        guard stem == id || (stem.hasPrefix(id + ".") && stem.count > id.count + 1) else { return false }
        for other in otherBundleIDs where other != id && other.hasPrefix(id + ".") {
            if stem == other || stem.hasPrefix(other + ".") { return false }
        }
        return true
    }

    /// Everything the app left in `library`, sized.
    ///
    /// `library` is injected so tests run against a scratch folder instead of
    /// the real ~/Library. User-level only: /Library needs an admin password
    /// and is out of scope.
    public static func leftovers(for app: InstalledApp, library: URL,
                                 otherBundleIDs: Set<String> = []) -> LeftoverScan {
        let fm = FileManager.default
        var scan = LeftoverScan()
        for location in LeftoverLocation.allCases {
            let dir = library.appending(path: location.folder, directoryHint: .isDirectory)
            let names: [String]
            if location.usesPattern {
                names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { location.matches($0, for: app, otherBundleIDs: otherBundleIDs) }
            } else {
                // Probe each exact name instead of listing the folder. Listing
                // ~/Library/Containers would show every other app's container
                // names, and none of them are ours to read.
                names = location.exactNames(for: app).filter { entryExists(dir.appending(path: $0), named: $0) }
            }
            // An app whose file name equals its bundle id would list twice.
            for name in Set(names).sorted() {
                let url = dir.appending(path: name)
                guard isTrashableLeftover(url, for: app, library: library, otherBundleIDs: otherBundleIDs) else {
                    scan.ignored.append(url.path)
                    continue
                }
                scan.found.append(Leftover(url: url, kind: location.folder, bytes: DiskScan.size(of: url)))
            }
        }
        return scan
    }

    /// True only if something is there under exactly this spelling. The volume
    /// is usually case-insensitive, so "slack" would otherwise find "Slack";
    /// asking the file system for the stored name settles it. Does not follow
    /// a final symlink, so a broken link still counts as present.
    static func entryExists(_ url: URL, named name: String) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return false }
        return (try? url.resourceValues(forKeys: [.nameKey]).name) == name
    }

    /// The last check before a leftover is moved, and the reason a symlink in a
    /// Library folder can never get anything outside it trashed.
    ///
    /// Resolves first, then requires that the real path is an exact-name match
    /// sitting directly inside one of the known Library folders, which are
    /// themselves real folders inside `library`. A link out to Documents
    /// resolves to a path whose parent is Documents, and fails.
    public static func isTrashableLeftover(_ url: URL, for app: InstalledApp, library: URL,
                                           otherBundleIDs: Set<String> = []) -> Bool {
        let lib = library.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let parts = resolved.pathComponents
        guard !parts.contains(".."), parts.count > lib.count + 1,
              Array(parts.prefix(lib.count)) == lib else { return false }
        let folder = parts[lib.count]
        guard parts.count == lib.count + 2,
              let location = LeftoverLocation.allCases.first(where: { $0.folder == folder }) else { return false }
        // Both spellings must match: the name it was listed under and the name
        // it really has, so a link called after this app that points at a
        // sibling's folder is refused too.
        return location.matches(url.lastPathComponent, for: app, otherBundleIDs: otherBundleIDs)
            && location.matches(resolved.lastPathComponent, for: app, otherBundleIDs: otherBundleIDs)
    }

    // MARK: Removing

    public static let systemMover: TrashMover = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    /// Moves the app and the chosen leftovers to the Trash. Never deletes.
    ///
    /// The app goes first. If it cannot be moved, its leftovers stay put:
    /// stripping the preferences from an app that is still installed would
    /// leave the user worse off than doing nothing.
    public static func trash(app: InstalledApp, includeApp: Bool, leftovers: [Leftover],
                             appRoots: [URL], library: URL, running: RunningApps,
                             otherBundleIDs: Set<String> = [],
                             mover: TrashMover = systemMover) -> TrashOutcome {
        var outcome = TrashOutcome()

        if let why = refusal(for: app, appRoots: appRoots, running: running) {
            let reason = why.message(for: app.name)
            if includeApp { outcome.skipped.append(SkippedItem(path: app.url.path, reason: reason)) }
            for l in leftovers { outcome.skipped.append(SkippedItem(path: l.url.path, reason: reason)) }
            return outcome
        }

        var appFailed = false
        if includeApp {
            do {
                let dest = try mover(app.url)
                outcome.moved.append(MovedItem(original: app.url, trashed: dest, bytes: app.bytes ?? 0))
            } catch {
                appFailed = true
                outcome.skipped.append(SkippedItem(path: app.url.path,
                                                   reason: "Could not be moved: \(error.localizedDescription)"))
            }
        }

        for l in leftovers {
            if appFailed {
                outcome.skipped.append(SkippedItem(path: l.url.path,
                                                   reason: "Kept, because the app itself could not be moved."))
                continue
            }
            guard isTrashableLeftover(l.url, for: app, library: library, otherBundleIDs: otherBundleIDs) else {
                outcome.skipped.append(SkippedItem(path: l.url.path, reason: "Failed the safety check."))
                continue
            }
            do {
                let dest = try mover(l.url)
                outcome.moved.append(MovedItem(original: l.url, trashed: dest, bytes: l.bytes))
            } catch {
                outcome.skipped.append(SkippedItem(path: l.url.path,
                                                   reason: "Could not be moved: \(error.localizedDescription)"))
            }
        }
        return outcome
    }

    /// Puts moved items back where they came from. Refuses to overwrite: if
    /// something new has appeared at the old path, that is the user's now.
    public static func restore(_ items: [MovedItem]) -> (restored: Int, failed: Int) {
        let fm = FileManager.default
        var restored = 0, failed = 0
        for item in items {
            let parent = item.original.deletingLastPathComponent().path
            guard fm.fileExists(atPath: item.trashed.path),
                  fm.fileExists(atPath: parent),
                  (try? fm.attributesOfItem(atPath: item.original.path)) == nil else {
                failed += 1
                continue
            }
            do {
                try fm.moveItem(at: item.trashed, to: item.original)
                restored += 1
            } catch {
                failed += 1
            }
        }
        return (restored, failed)
    }
}
