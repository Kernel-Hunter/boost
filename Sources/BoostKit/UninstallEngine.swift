import Foundation
import AppKit
import SwiftUI

/// What the detail pane shows after a removal: honest about what moved and what
/// did not, with the means to undo it.
public struct UninstallResult {
    public let appName: String
    public let appPath: String
    public let moved: [MovedItem]
    public let skipped: [SkippedItem]
    public var bytes: UInt64 { moved.reduce(0) { $0 + $1.bytes } }
}

/// State for the Uninstall tab. Separate from `DiskEngine` for the same
/// reason that one is separate from `Engine`: different work, different pace.
/// Listing apps is quick, sizing them is not, and finding leftovers sits in
/// between.
@MainActor
public final class UninstallEngine: ObservableObject {
    public static let shared = UninstallEngine()

    @Published public private(set) var apps: [InstalledApp] = []
    @Published public private(set) var loading = false
    @Published public var search = ""
    @Published public var sort: AppSort = .name {
        didSet { if sort != oldValue { ascending = sort.defaultAscending } }
    }
    @Published public var ascending = true

    @Published public private(set) var selected: InstalledApp?
    @Published public private(set) var refusal: Refusal?
    @Published public private(set) var leftovers: [Leftover] = []
    @Published public private(set) var ignoredCount = 0
    @Published public private(set) var scanningLeftovers = false
    /// Paths that are ticked: the app's own, and any leftover. Ticked by
    /// default because the user chose this app; each one can be unticked.
    @Published public var ticked: Set<String> = []

    @Published public var confirming = false
    @Published public private(set) var trashing = false
    @Published public private(set) var result: UninstallResult?
    @Published public var dropTargeted = false
    @Published public private(set) var notice: String?

    /// Sizes survive a reload, so putting an app back or rescanning does not
    /// make the whole list re-measure.
    private var sizeCache: [String: UInt64] = [:]
    private var loadGeneration = 0
    private var selectionToken = UUID()

    private var library: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
    }
    private var appRoots: [URL] { AppScan.defaultRoots() }
    private var allBundleIDs: Set<String> { Set(apps.compactMap(\.bundleID)) }

    // MARK: Derived

    public var visibleApps: [InstalledApp] {
        AppScan.visible(apps, query: search, sort: sort, ascending: ascending)
    }
    public var includesApp: Bool {
        guard let app = selected else { return false }
        return ticked.contains(app.id)
    }
    public var chosenLeftovers: [Leftover] { leftovers.filter { ticked.contains($0.id) } }
    public var chosenCount: Int { chosenLeftovers.count + (includesApp ? 1 : 0) }
    public var chosenBytes: UInt64 {
        chosenLeftovers.reduce(0) { $0 + $1.bytes } + (includesApp ? (selected?.bytes ?? 0) : 0)
    }
    public var canTrash: Bool {
        selected != nil && refusal == nil && chosenCount > 0 && !trashing && !scanningLeftovers
    }

    // MARK: Listing

    public func load() {
        guard !loading else { return }
        Task { await reload() }
    }

    private func reload() async {
        loading = true
        loadGeneration += 1
        let generation = loadGeneration
        let found = await Task.detached(priority: .userInitiated) {
            AppScan.discoverApps(in: AppScan.defaultRoots())
        }.value
        guard generation == loadGeneration else { return }
        apps = found.map { app in
            var a = app
            a.bytes = sizeCache[app.id]
            return a
        }
        loading = false

        for app in apps where app.bytes == nil {
            let url = app.url
            let bytes = await Task.detached(priority: .utility) { DiskScan.size(of: url) }.value
            guard generation == loadGeneration else { return }
            sizeCache[app.id] = bytes
            if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].bytes = bytes }
            if selected?.id == app.id { selected?.bytes = bytes }
        }
    }

    // MARK: Selecting

    public func select(_ app: InstalledApp) {
        result = nil
        notice = nil
        var app = app
        app.bytes = app.bytes ?? sizeCache[app.id]
        selected = app
        leftovers = []
        ignoredCount = 0
        ticked = [app.id]

        refusal = AppScan.refusal(for: app, appRoots: appRoots, running: Self.currentlyRunning())
        let token = UUID()
        selectionToken = token
        guard refusal == nil else {
            scanningLeftovers = false
            return
        }

        scanningLeftovers = true
        let lib = library
        let others = allBundleIDs
        let needsSize = app.bytes == nil
        // A `let` copy: capturing the mutable local would not be Sendable.
        let snapshot = app
        Task {
            let (scan, bytes) = await Task.detached(priority: .userInitiated) { () -> (LeftoverScan, UInt64?) in
                let scan = AppScan.leftovers(for: snapshot, library: lib, otherBundleIDs: others)
                return (scan, needsSize ? DiskScan.size(of: snapshot.url) : nil)
            }.value
            guard selectionToken == token else { return }
            if let bytes {
                sizeCache[app.id] = bytes
                selected?.bytes = bytes
            }
            leftovers = scan.found.sorted { $0.bytes > $1.bytes }
            ignoredCount = scan.ignored.count
            ticked.formUnion(scan.found.map(\.id))
            scanningLeftovers = false
        }
    }

    /// Looks at the app again, for after the user has quit it.
    public func recheck() {
        if let app = selected { select(app) }
    }

    /// Drag and drop. Anything that is not a readable `.app` is said so rather
    /// than ignored, and an app outside the two Applications folders is shown
    /// with its refusal instead of being silently dropped.
    @discardableResult
    public func select(dropped urls: [URL]) -> Bool {
        guard let url = urls.first(where: { $0.pathExtension == "app" }) else {
            flash("That is not an app. Drop a .app file.")
            return false
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let known = apps.first(where: { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == resolved }) {
            select(known)
            return true
        }
        guard let app = AppScan.readApp(at: url.standardizedFileURL) else {
            flash("Could not read that app.")
            return false
        }
        select(app)
        return true
    }

    public func clearSelection() {
        selectionToken = UUID()
        selected = nil
        refusal = nil
        leftovers = []
        ticked = []
        scanningLeftovers = false
        result = nil
    }

    // MARK: Ticking

    public func toggle(_ id: String) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    public func revealSelected() {
        guard let app = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    // MARK: Removing

    public func trash() {
        guard let app = selected, canTrash else { return }

        // Looked at again now, not at selection time: the app may have been
        // opened since the list was drawn.
        let running = Self.currentlyRunning()
        if let why = AppScan.refusal(for: app, appRoots: appRoots, running: running) {
            refusal = why
            return
        }

        trashing = true
        let includeApp = includesApp
        let chosen = chosenLeftovers
        let lib = library
        let roots = appRoots
        let others = allBundleIDs
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                AppScan.trash(app: app, includeApp: includeApp, leftovers: chosen,
                              appRoots: roots, library: lib, running: running,
                              otherBundleIDs: others)
            }.value

            result = UninstallResult(appName: app.name, appPath: app.url.path,
                                     moved: outcome.moved, skipped: outcome.skipped)
            if outcome.moved.contains(where: { $0.original == app.url }) {
                apps.removeAll { $0.id == app.id }
                sizeCache[app.id] = nil
            }
            selected = nil
            leftovers = []
            ticked = []
            refusal = nil
            trashing = false
        }
    }

    /// Puts everything from the last removal back where it was.
    public func undo() {
        guard let done = result, !done.moved.isEmpty else { return }
        let items = done.moved
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                AppScan.restore(items)
            }.value
            result = nil
            await reload()
            if let back = apps.first(where: { $0.id == done.appPath }) { select(back) }
            flash(outcome.failed == 0
                  ? "Put back \(outcome.restored) \(outcome.restored == 1 ? "item" : "items")."
                  : "Put back \(outcome.restored). \(outcome.failed) could not be restored, "
                    + "so they are still in the Trash.")
        }
    }

    public func revealInTrash() {
        guard let done = result else { return }
        NSWorkspace.shared.activateFileViewerSelecting(done.moved.map(\.trashed))
    }

    public func dismissResult() { result = nil }

    // MARK: Helpers

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == text { notice = nil }
        }
    }

    /// Read on the main actor and handed over as plain values: the workspace's
    /// running-app list is an AppKit object and not meant to be walked from a
    /// background thread.
    private static func currentlyRunning() -> RunningApps {
        let running = NSWorkspace.shared.runningApplications
        return RunningApps(
            ids: Set(running.compactMap(\.bundleIdentifier)),
            paths: Set(running.compactMap { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path }))
    }
}
