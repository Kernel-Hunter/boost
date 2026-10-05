import Testing
import Foundation
@testable import BoostKit

// An uninstaller that matches loosely takes someone else's data with it, and
// the person finds out when another app has forgotten its settings. These
// tests pin the other direction: what is NOT matched matters more than what is.

/// A scratch Mac: a fake home with a Library and an Applications folder, so
/// nothing here touches the real ones.
private struct Scratch {
    let root: URL
    let library: URL
    let applications: URL
    let documents: URL
    let fm = FileManager.default

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "boost-uninstall-\(UUID().uuidString)")
        library = root.appending(path: "home/Library")
        applications = root.appending(path: "Applications")
        documents = root.appending(path: "home/Documents")
        for dir in [library, applications, documents] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func cleanup() { try? fm.removeItem(at: root) }

    /// A bundle with just enough of an Info.plist to be read as an app.
    @discardableResult
    func makeApp(_ fileName: String, id: String?, bundleName: String? = nil,
                 in dir: URL? = nil) throws -> InstalledApp {
        let url = (dir ?? applications).appending(path: "\(fileName).app")
        let contents = url.appending(path: "Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": "1.0"]
        if let id { info["CFBundleIdentifier"] = id }
        if let bundleName { info["CFBundleName"] = bundleName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        try Data(repeating: 1, count: 32 * 1024).write(to: contents.appending(path: "payload.bin"))
        return try #require(AppScan.readApp(at: url))
    }

    /// Creates `Library/<relative>` as a folder holding one file, or as a bare
    /// file when the name ends in .plist.
    func put(_ relative: String, kilobytes: Int = 4) throws {
        let url = library.appending(path: relative)
        let data = Data(repeating: 7, count: kilobytes * 1024)
        if url.pathExtension == "plist" {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appending(path: "blob.bin"))
        }
    }

    func found(for app: InstalledApp, others: Set<String> = []) -> [String] {
        let base = library.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return AppScan.leftovers(for: app, library: library, otherBundleIDs: others).found
            .map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }
            .sorted()
    }
}

/// Records what would have been moved, and can be told to fail for a path.
private final class RecordingMover: @unchecked Sendable {
    private let lock = NSLock()
    private var _moved: [String] = []
    private let failing: Set<String>
    init(failing: Set<String> = []) { self.failing = failing }

    var moved: [String] { lock.withLock { _moved } }

    var mover: TrashMover {
        { [self] url in
            if failing.contains(url.path) { throw CocoaError(.fileWriteNoPermission) }
            lock.withLock { _moved.append(url.path) }
            return url
        }
    }
}

// MARK: - What is matched

@Suite("Uninstall: exact matches only")
struct AppScanMatchTests {

    @Test("Finds every location by exact bundle id or exact app name")
    func findsExactMatches() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.tinyspeck.slackmacgap")
        let id = "com.tinyspeck.slackmacgap"

        try s.put("Application Support/\(id)")
        try s.put("Application Support/Slack")
        try s.put("Caches/\(id)")
        try s.put("Preferences/\(id).plist")
        try s.put("Preferences/\(id).helper.plist")
        try s.put("Containers/\(id)")
        try s.put("Group Containers/\(id)")
        try s.put("Group Containers/group.\(id)")
        try s.put("Saved Application State/\(id).savedState")
        try s.put("Logs/Slack")
        try s.put("HTTPStorages/\(id)")
        try s.put("WebKit/\(id)")
        try s.put("LaunchAgents/\(id).agent.plist")

        #expect(s.found(for: app) == [
            "Application Support/Slack",
            "Application Support/\(id)",
            "Caches/\(id)",
            "Containers/\(id)",
            "Group Containers/\(id)",
            "Group Containers/group.\(id)",
            "HTTPStorages/\(id)",
            "LaunchAgents/\(id).agent.plist",
            "Logs/Slack",
            "Preferences/\(id).helper.plist",
            "Preferences/\(id).plist",
            "Saved Application State/\(id).savedState",
            "WebKit/\(id)",
        ].sorted())
    }

    /// The case this whole feature exists to get right.
    @Test("Scanning Slack does not pick up Slack Helper or other look-alikes")
    func lookAlikesAreNotMatched() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")

        try s.put("Application Support/Slack Helper")
        try s.put("Application Support/Slacker")
        try s.put("Application Support/Slack-old")
        try s.put("Application Support/com.foo.SlackHelper")
        try s.put("Caches/com.foo.Slack.helper")          // Caches takes the id and nothing longer
        try s.put("Caches/com.foo.SlackHelper")
        try s.put("Logs/Slack Helper")
        try s.put("Logs/Slack/nested")                    // inside a match, not a match itself
        try s.put("Preferences/com.foo.SlackHelper.plist")
        try s.put("Preferences/com.foo.Slacker.plist")
        try s.put("Preferences/com.foo.plist")
        try s.put("LaunchAgents/com.foo.Slack-agent.plist")   // id must be followed by a dot
        try s.put("LaunchAgents/other.com.foo.Slack.plist")
        try s.put("Group Containers/ABCDE12345.com.foo.Slack") // Team ID form: cannot be proven ours
        try s.put("Group Containers/group.com.foo.SlackHelper")
        try s.put("Containers/com.foo.Slack.extension")

        // Only the Logs/Slack folder itself is an exact name here.
        #expect(s.found(for: app) == ["Logs/Slack"])
    }

    @Test("A name that differs only in case is not an exact match")
    func caseMustMatch() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        // The volume is usually case-insensitive, so fileExists("slack") is
        // true for a folder called "Slack". The scan must not be fooled.
        try s.put("Application Support/slack")
        try s.put("Caches/com.foo.slack")
        #expect(s.found(for: app).isEmpty)
    }

    @Test("A longer bundle id owned by another installed app keeps its own files")
    func nestedBundleIDsDoNotClaimEachOther() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Chrome", id: "com.google.Chrome")
        try s.put("Preferences/com.google.Chrome.plist")
        try s.put("Preferences/com.google.Chrome.canary.plist")

        // Without knowing about Canary, the dotted rule would take its file.
        #expect(s.found(for: app, others: ["com.google.Chrome.canary"])
                == ["Preferences/com.google.Chrome.plist"])
    }

    @Test("CFBundleName is matched when it differs from the file name")
    func bundleNameIsAnExactName() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Visual Studio Code", id: "com.microsoft.VSCode", bundleName: "Code")
        try s.put("Application Support/Code")
        try s.put("Application Support/Code - Insiders")
        #expect(s.found(for: app) == ["Application Support/Code"])
    }

    @Test("An app with no bundle id is matched by name alone")
    func noBundleID() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Tiny", id: nil)
        try s.put("Application Support/Tiny")
        try s.put("Application Support/Tiny Two")
        try s.put("Preferences/anything.plist")
        #expect(s.found(for: app) == ["Application Support/Tiny"])
    }

    @Test("Names that could climb out of a folder are never used", arguments: ["..", ".", "a/b", ""])
    func unsafeNamesAreIgnored(name: String) throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = InstalledApp(url: s.applications.appending(path: "X.app"), name: name,
                               matchNames: [name], bundleID: name, version: nil, lastUsed: nil, bytes: nil)
        try s.put("Application Support/real")
        #expect(s.found(for: app).isEmpty)
    }
}

// MARK: - Refusals

@Suite("Uninstall: what is refused")
struct AppScanRefusalTests {

    private func refusal(_ s: Scratch, _ app: InstalledApp, running: RunningApps = .none) -> Refusal? {
        AppScan.refusal(for: app, appRoots: [s.applications], running: running)
    }

    @Test("Anything com.apple.* is refused", arguments: ["com.apple.Safari", "com.apple.dt.Xcode", "COM.APPLE.Foo"])
    func appleIsRefused(id: String) throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Thing", id: id)
        #expect(refusal(s, app) == .apple)
    }

    @Test("A bundle id that only contains apple is not Apple's")
    func appleLookAlike() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Thing", id: "com.applesauce.Thing")
        #expect(refusal(s, app) == nil)
    }

    @Test("Boost cannot remove itself")
    func boostIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Boost", id: "boost.local.app")
        #expect(refusal(s, app) == .boost)
    }

    @Test("A running app is refused, by id or by path, and never quit for you")
    func runningIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        #expect(refusal(s, app, running: RunningApps(ids: ["com.foo.Slack"])) == .running)
        let path = app.url.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(refusal(s, app, running: RunningApps(paths: [path])) == .running)
        #expect(refusal(s, app, running: RunningApps(ids: ["com.other.App"])) == nil)
    }

    @Test("An app outside the Applications folders is refused")
    func outsideIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let elsewhere = s.root.appending(path: "Downloads")
        try s.fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let app = try s.makeApp("Loose", id: "com.foo.Loose", in: elsewhere)
        #expect(refusal(s, app) == .outsideApplications)
    }

    @Test("An entry in Applications that is a link to somewhere else is refused")
    func symlinkedAppIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let elsewhere = s.root.appending(path: "Volumes")
        try s.fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = try s.makeApp("Real", id: "com.foo.Real", in: elsewhere)
        let link = s.applications.appending(path: "Real.app")
        try s.fm.createSymbolicLink(at: link, withDestinationURL: real.url)

        let viaLink = try #require(AppScan.readApp(at: link))
        #expect(refusal(s, viaLink) == .outsideApplications)
    }

    @Test("An ordinary app in Applications is allowed")
    func ordinaryIsAllowed() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        #expect(refusal(s, app) == nil)
    }

    @Test("Nothing moves for a refused app, leftovers included")
    func refusedMovesNothing() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put("Caches/com.foo.Slack")
        let scan = AppScan.leftovers(for: app, library: s.library)
        let rec = RecordingMover()

        let out = AppScan.trash(app: app, includeApp: true, leftovers: scan.found,
                                appRoots: [s.applications], library: s.library,
                                running: RunningApps(ids: ["com.foo.Slack"]), mover: rec.mover)
        #expect(rec.moved.isEmpty)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.count == 2)
    }
}

// MARK: - Symlinks

@Suite("Uninstall: symlinks never lead out")
struct AppScanSymlinkTests {

    /// Spelled as a cache path, lands in Documents. Same trap the disk cleaner
    /// guards against, in a new place.
    @Test("A link in a leftover location pointing outside is never trashed")
    func linkOutIsNeverTrashed() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")

        let precious = s.documents.appending(path: "thesis")
        try s.fm.createDirectory(at: precious, withIntermediateDirectories: true)
        try "do not delete".write(to: precious.appending(path: "chapter.txt"), atomically: true, encoding: .utf8)

        let trap = s.library.appending(path: "Caches/com.foo.Slack")
        try s.fm.createDirectory(at: trap.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.fm.createSymbolicLink(at: trap, withDestinationURL: precious)

        // The scan neither lists it nor pretends it did not see it.
        let scan = AppScan.leftovers(for: app, library: s.library)
        #expect(scan.found.isEmpty)
        #expect(scan.ignored.count == 1)
        #expect(!AppScan.isTrashableLeftover(trap, for: app, library: s.library))

        // And if something hands it over anyway, the check before the move catches it.
        let forged = Leftover(url: trap, kind: "Caches", bytes: 1)
        let rec = RecordingMover()
        let out = AppScan.trash(app: app, includeApp: false, leftovers: [forged],
                                appRoots: [s.applications], library: s.library,
                                running: .none, mover: rec.mover)
        #expect(rec.moved.isEmpty)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.count == 1)
        #expect(s.fm.fileExists(atPath: precious.appending(path: "chapter.txt").path))
    }

    @Test("A link to a sibling folder inside the same Library folder is refused too")
    func linkToSiblingIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put("Caches/com.other.App")
        let link = s.library.appending(path: "Caches/com.foo.Slack")
        try s.fm.createSymbolicLink(at: link, withDestinationURL: s.library.appending(path: "Caches/com.other.App"))
        #expect(!AppScan.isTrashableLeftover(link, for: app, library: s.library))
        #expect(AppScan.leftovers(for: app, library: s.library).found.isEmpty)
    }

    @Test("A Library folder that is itself a link out is not searched")
    func linkedLibraryFolderIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        let elsewhere = s.root.appending(path: "external-caches")
        try s.fm.createDirectory(at: elsewhere.appending(path: "com.foo.Slack"), withIntermediateDirectories: true)
        try s.fm.createSymbolicLink(at: s.library.appending(path: "Caches"), withDestinationURL: elsewhere)

        #expect(AppScan.leftovers(for: app, library: s.library).found.isEmpty)
        #expect(!AppScan.isTrashableLeftover(s.library.appending(path: "Caches/com.foo.Slack"),
                                             for: app, library: s.library))
    }

    @Test("Paths that are not exact matches fail the final check even if they exist",
          arguments: ["Caches/com.foo.SlackHelper", "Application Support", "Caches", "Documents/x"])
    func finalCheckRefusesStrangers(relative: String) throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put(relative)
        #expect(!AppScan.isTrashableLeftover(s.library.appending(path: relative), for: app, library: s.library))
    }

    @Test("Something outside the Library fails the final check")
    func outsideLibraryIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        let outside = s.documents.appending(path: "Caches/com.foo.Slack")
        try s.fm.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(!AppScan.isTrashableLeftover(outside, for: app, library: s.library))
    }
}

// MARK: - Sizes

@Suite("Uninstall: sizes")
struct AppScanSizeTests {

    @Test("A leftover's size is the sum of what is in it")
    func sizesAreSummed() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        let dir = s.library.appending(path: "Application Support/com.foo.Slack")
        try s.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64 * 1024).write(to: dir.appending(path: "a.bin"))
        try Data(repeating: 2, count: 64 * 1024).write(to: dir.appending(path: "b.bin"))

        let item = try #require(AppScan.leftovers(for: app, library: s.library).found.first)
        #expect(item.bytes >= 128 * 1024)
    }

    @Test("A link inside a leftover is not followed when sizing")
    func sizingDoesNotFollowLinks() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        let big = s.documents.appending(path: "big")
        try s.fm.createDirectory(at: big, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024 * 1024).write(to: big.appending(path: "big.bin"))

        let dir = s.library.appending(path: "Application Support/com.foo.Slack")
        try s.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64 * 1024).write(to: dir.appending(path: "a.bin"))
        try s.fm.createSymbolicLink(at: dir.appending(path: "link"), withDestinationURL: big)

        let item = try #require(AppScan.leftovers(for: app, library: s.library).found.first)
        #expect(item.bytes >= 64 * 1024)
        #expect(item.bytes < 512 * 1024)      // the 1 MB behind the link is not ours
    }
}

// MARK: - Removing, and putting back

@Suite("Uninstall: moving to the Trash")
struct AppScanTrashTests {

    @Test("The app goes first, then each ticked leftover, and nothing else")
    func movesAppThenLeftovers() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put("Caches/com.foo.Slack")
        try s.put("Logs/Slack")
        try s.put("Caches/com.foo.SlackHelper")        // look-alike, must stay
        let scan = AppScan.leftovers(for: app, library: s.library)
        let rec = RecordingMover()

        let out = AppScan.trash(app: app, includeApp: true, leftovers: scan.found,
                                appRoots: [s.applications], library: s.library,
                                running: .none, mover: rec.mover)
        #expect(out.skipped.isEmpty)
        #expect(rec.moved.first == app.url.path)
        #expect(Set(rec.moved.dropFirst().map { URL(fileURLWithPath: $0).lastPathComponent })
                == ["com.foo.Slack", "Slack"])
        #expect(!rec.moved.contains { $0.hasSuffix("SlackHelper") })
    }

    @Test("Unticking the app leaves it installed")
    func appCanBeLeftOut() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put("Caches/com.foo.Slack")
        let scan = AppScan.leftovers(for: app, library: s.library)
        let rec = RecordingMover()
        _ = AppScan.trash(app: app, includeApp: false, leftovers: scan.found,
                          appRoots: [s.applications], library: s.library, running: .none, mover: rec.mover)
        #expect(!rec.moved.contains(app.url.path))
        #expect(rec.moved.count == 1)
    }

    @Test("If the app cannot be moved its leftovers are kept, and the report says so")
    func failedAppKeepsLeftovers() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put("Caches/com.foo.Slack")
        let scan = AppScan.leftovers(for: app, library: s.library)
        let rec = RecordingMover(failing: [app.url.path])

        let out = AppScan.trash(app: app, includeApp: true, leftovers: scan.found,
                                appRoots: [s.applications], library: s.library,
                                running: .none, mover: rec.mover)
        #expect(rec.moved.isEmpty)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.count == 2)
    }

    @Test("One leftover failing does not stop the rest, and is reported")
    func partialFailureIsReported() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put("Caches/com.foo.Slack")
        try s.put("Logs/Slack")
        let scan = AppScan.leftovers(for: app, library: s.library)
        let stuck = try #require(scan.found.first { $0.kind == "Caches" })
        let rec = RecordingMover(failing: [stuck.url.path])

        let out = AppScan.trash(app: app, includeApp: true, leftovers: scan.found,
                                appRoots: [s.applications], library: s.library,
                                running: .none, mover: rec.mover)
        #expect(out.moved.count == 2)
        #expect(out.skipped.map(\.path) == [stuck.url.path])
    }

    /// Uses a throwaway folder as the Trash, so the real one is never touched.
    @Test("What was moved can be put back, and nothing is overwritten")
    func restoreRoundTrip() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let app = try s.makeApp("Slack", id: "com.foo.Slack")
        try s.put("Caches/com.foo.Slack")
        let scan = AppScan.leftovers(for: app, library: s.library)
        let trashDir = s.root.appending(path: "Trash")
        try s.fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let fakeTrash: TrashMover = { url in
            let dest = trashDir.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }

        let out = AppScan.trash(app: app, includeApp: true, leftovers: scan.found,
                                appRoots: [s.applications], library: s.library,
                                running: .none, mover: fakeTrash)
        #expect(out.moved.count == 2)
        #expect(!s.fm.fileExists(atPath: app.url.path))
        #expect(!s.fm.fileExists(atPath: scan.found[0].url.path))

        // Something new now sits where the cache was: that one must not be replaced.
        try s.fm.createDirectory(at: scan.found[0].url, withIntermediateDirectories: true)
        let back = AppScan.restore(out.moved)
        #expect(back.restored == 1)
        #expect(back.failed == 1)
        #expect(s.fm.fileExists(atPath: app.url.path))
    }
}

// MARK: - Discovery and list

@Suite("Uninstall: finding and listing apps")
struct AppScanListTests {

    @Test("Lists apps one level deep and skips folders that only look like apps")
    func discovery() throws {
        let s = try Scratch(); defer { s.cleanup() }
        try s.makeApp("Slack", id: "com.foo.Slack")
        try s.fm.createDirectory(at: s.applications.appending(path: "Empty.app"), withIntermediateDirectories: true)
        try s.fm.createDirectory(at: s.applications.appending(path: "Utilities"), withIntermediateDirectories: true)
        try s.makeApp("Deep", id: "com.foo.Deep", in: s.applications.appending(path: "Utilities"))

        let apps = AppScan.discoverApps(in: [s.applications, s.root.appending(path: "no-such-folder")])
        #expect(apps.map(\.name) == ["Slack"])
        #expect(apps.first?.bundleID == "com.foo.Slack")
        #expect(apps.first?.version == "1.0")
    }

    @Test("An app reachable through two roots is listed once")
    func deduplicates() throws {
        let s = try Scratch(); defer { s.cleanup() }
        try s.makeApp("Slack", id: "com.foo.Slack")
        let alias = s.root.appending(path: "home/Applications")
        try s.fm.createSymbolicLink(at: alias, withDestinationURL: s.applications)
        #expect(AppScan.discoverApps(in: [s.applications, alias]).count == 1)
    }

    private func sample() -> [InstalledApp] {
        func app(_ n: String, bytes: UInt64?, used: Double?) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: "/Applications/\(n).app"), name: n, matchNames: [n],
                         bundleID: "com.x.\(n.lowercased())", version: nil,
                         lastUsed: used.map { Date(timeIntervalSince1970: $0) }, bytes: bytes)
        }
        return [app("Bravo", bytes: 300, used: 2000), app("alpha", bytes: nil, used: nil),
                app("Charlie", bytes: 100, used: 1000), app("Delta", bytes: 200, used: nil)]
    }

    @Test("Sorts by name, size and last used, with unknown values last either way")
    func sorting() {
        let apps = sample()
        func names(_ sort: AppSort, _ asc: Bool) -> [String] {
            AppScan.visible(apps, query: "", sort: sort, ascending: asc).map(\.name)
        }
        #expect(names(.name, true) == ["alpha", "Bravo", "Charlie", "Delta"])
        #expect(names(.name, false) == ["Delta", "Charlie", "Bravo", "alpha"])
        #expect(names(.size, false) == ["Bravo", "Delta", "Charlie", "alpha"])
        #expect(names(.size, true) == ["Charlie", "Delta", "Bravo", "alpha"])
        #expect(names(.lastUsed, true) == ["Charlie", "Bravo", "alpha", "Delta"])
        #expect(names(.lastUsed, false) == ["Bravo", "Charlie", "alpha", "Delta"])
    }

    @Test("Search matches the name or the bundle id, ignoring case")
    func searching() {
        let apps = sample()
        #expect(AppScan.visible(apps, query: "CHAR", sort: .name, ascending: true).map(\.name) == ["Charlie"])
        #expect(AppScan.visible(apps, query: "com.x.delta", sort: .name, ascending: true).map(\.name) == ["Delta"])
        #expect(AppScan.visible(apps, query: "  ", sort: .name, ascending: true).count == 4)
        #expect(AppScan.visible(apps, query: "zzz", sort: .name, ascending: true).isEmpty)
    }
}
