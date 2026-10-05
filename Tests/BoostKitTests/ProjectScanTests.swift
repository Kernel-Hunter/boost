import Testing
import Foundation
@testable import BoostKit

// All of these run against temporary directories. None of them touches the real
// Trash: moves go through an injected closure.

private var fm: FileManager { .default }

/// A fresh temp directory, already symlink-resolved (/var is /private/var on
/// macOS, and the scanner compares resolved paths).
private func makeRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "boost-projects-\(UUID().uuidString)")
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return ProjectScan.canonical(url)
}

private func daysAgo(_ n: Int) -> Date { Date().addingTimeInterval(-Double(n) * 86_400) }

private func setDate(_ url: URL, _ date: Date) throws {
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

/// Back-dates a file or an entire tree.
private func age(_ url: URL, days: Int) throws {
    let date = daysAgo(days)
    if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let child as URL in e { try setDate(child, date) }
    }
    try setDate(url, date)
}

/// Builds `<parent>/<name>/<folder>/pkg/blob.bin` plus the proof of what it is.
/// `sibling` is a manifest next to the folder; `inside` a marker within it.
/// Everything is back-dated `idle` days, so the project looks abandoned.
@discardableResult
private func makeProject(
    in parent: URL, name: String = "app", folder: String,
    sibling: String? = nil, inside: String? = nil, idle: Int = 90, blobKB: Int = 64
) throws -> URL {
    let project = parent.appending(path: name)
    let target = project.appending(path: folder)
    try fm.createDirectory(at: target.appending(path: "pkg"), withIntermediateDirectories: true)
    try Data(repeating: 1, count: blobKB * 1024).write(to: target.appending(path: "pkg/blob.bin"))
    if let sibling { try "x".write(to: project.appending(path: sibling), atomically: true, encoding: .utf8) }
    if let inside { try "x".write(to: target.appending(path: inside), atomically: true, encoding: .utf8) }
    try age(target, days: idle)
    if let sibling { try setDate(project.appending(path: sibling), daysAgo(idle)) }
    return target
}

@Suite("Projects: what qualifies")
struct ProjectDetectionTests {

    @Test("Each kind is found when its manifest sits beside it", arguments: [
        ("node_modules", "package.json", ProjectKind.node),
        (".build", "Package.swift", ProjectKind.swiftPM),
        ("target", "Cargo.toml", ProjectKind.cargo),
        ("Pods", "Podfile", ProjectKind.cocoaPods),
        ("build", "build.gradle", ProjectKind.gradle),
        ("build", "build.gradle.kts", ProjectKind.gradle),
        (".next", "package.json", ProjectKind.next),
        (".nuxt", "package.json", ProjectKind.nuxt),
    ])
    func foundWithManifest(folder: String, manifest: String, kind: ProjectKind) throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: folder, sibling: manifest)

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(r.items.map(\.url.path) == [target.path])
        #expect(r.items.first?.kind == kind)
    }

    @Test("The same names are ignored without a manifest, because the name alone proves nothing", arguments: [
        "node_modules", ".build", "target", "Pods", "build", ".next", ".nuxt", ".venv", "venv",
    ])
    func ignoredWithoutManifest(folder: String) throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root, folder: folder)

        #expect(ProjectScan.scan(roots: [root], olderThanDays: 30).items.isEmpty)
    }

    @Test("A node_modules with no package.json beside it is ignored")
    func nodeModulesWithoutPackageJSON() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        // A sibling that merely looks related is not the manifest.
        try makeProject(in: root, folder: "node_modules", sibling: "package-lock.json")

        #expect(ProjectScan.scan(roots: [root], olderThanDays: 30).items.isEmpty)
    }

    @Test("A virtualenv is proven by pyvenv.cfg inside it", arguments: [".venv", "venv"])
    func virtualenv(folder: String) throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: folder, inside: "pyvenv.cfg")

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(r.items.map(\.url.path) == [target.path])
        #expect(r.items.first?.kind == .python)
    }

    @Test("Hidden folders and .git are not searched for projects")
    func hiddenFoldersSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root.appending(path: ".hidden"), folder: "node_modules", sibling: "package.json")
        try makeProject(in: root.appending(path: ".git"), folder: "node_modules", sibling: "package.json")

        #expect(ProjectScan.scan(roots: [root], olderThanDays: 30).items.isEmpty)
    }

    @Test("Folders deeper than six levels are skipped; six is included")
    func depthLimit() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        // node_modules at depth 6: a/b/c/d/proj/node_modules
        let ok = try makeProject(in: root.appending(path: "a/b/c/d"), name: "proj",
                                 folder: "node_modules", sibling: "package.json")
        // depth 7
        try makeProject(in: root.appending(path: "a/b/c/d/e"), name: "deep",
                        folder: "node_modules", sibling: "package.json")

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(r.items.map(\.url.path) == [ok.path])
    }

    @Test("A matched folder is not entered, so a nested match is not counted twice")
    func nestedMatchesNotDoubleCounted() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let outer = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        // A dependency that ships its own package.json and node_modules.
        let dep = outer.appending(path: "dep")
        try fm.createDirectory(at: dep.appending(path: "node_modules/inner"), withIntermediateDirectories: true)
        try "{}".write(to: dep.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 32 * 1024).write(to: dep.appending(path: "node_modules/inner/x.bin"))
        try age(outer, days: 90)

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(r.items.count == 1)
        #expect(r.items.first?.url.path == outer.path)
    }

    @Test("A folder reachable through two overlapping roots is listed once")
    func overlappingRoots() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root.appending(path: "work"), folder: "node_modules", sibling: "package.json")

        let r = ProjectScan.scan(roots: [root, root.appending(path: "work"), root], olderThanDays: 30)
        #expect(r.items.map(\.url.path) == [target.path])
    }

    @Test("Sorted by size, largest first")
    func sortedBySize() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root, name: "small", folder: "node_modules", sibling: "package.json", blobKB: 16)
        try makeProject(in: root, name: "big", folder: "node_modules", sibling: "package.json", blobKB: 512)
        try makeProject(in: root, name: "mid", folder: "node_modules", sibling: "package.json", blobKB: 128)

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(r.items.map(\.projectName) == ["big", "mid", "small"])
    }

    @Test("Sizing does not follow a symlink out of the folder")
    func sizingIgnoresSymlinks() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let elsewhere = root.appending(path: "elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: elsewhere.appending(path: "huge.bin"))

        let target = try makeProject(in: root.appending(path: "work"), folder: "node_modules",
                                     sibling: "package.json", blobKB: 4)
        let link = target.appending(path: "link")
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        // setAttributes follows links, so back-date the link itself.
        let t = timeval(tv_sec: Int(daysAgo(90).timeIntervalSince1970), tv_usec: 0)
        var times = [t, t]
        #expect(lutimes(link.path, &times) == 0)
        try setDate(target, daysAgo(90))

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(r.items.count == 1)
        #expect((r.items.first?.bytes ?? .max) < 1024 * 1024)
    }
}

@Suite("Projects: age")
struct ProjectAgeTests {

    @Test("Only projects older than the cutoff are listed")
    func cutoffRespected() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root, name: "stale", folder: "node_modules", sibling: "package.json", idle: 100)
        try makeProject(in: root, name: "fresh", folder: "node_modules", sibling: "package.json", idle: 20)

        #expect(ProjectScan.scan(roots: [root], olderThanDays: 30).items.map(\.projectName) == ["stale"])
        #expect(ProjectScan.scan(roots: [root], olderThanDays: 90).items.map(\.projectName) == ["stale"])
        #expect(ProjectScan.scan(roots: [root], olderThanDays: 180).items.isEmpty)
    }

    @Test("Reports how long the project has been untouched")
    func idleDaysReported() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root, folder: "node_modules", sibling: "package.json", idle: 100)

        let days = ProjectScan.scan(roots: [root], olderThanDays: 30).items.first?.idleDays
        #expect(days == 100)
    }

    /// An old package.json does not mean an old project: commits rewrite the index.
    @Test("A recent git index makes an old manifest count as active")
    func gitIndexCounts() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root, folder: "node_modules", sibling: "package.json", idle: 200)
        let git = root.appending(path: "app/.git")
        try fm.createDirectory(at: git, withIntermediateDirectories: true)
        let index = git.appending(path: "index")
        try "x".write(to: index, atomically: true, encoding: .utf8)
        try setDate(index, daysAgo(5))

        #expect(ProjectScan.scan(roots: [root], olderThanDays: 30).items.isEmpty)
    }

    @Test("A repository above the project counts too, as in a monorepo")
    func monorepoGitIndexCounts() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let repo = root.appending(path: "mono")
        try makeProject(in: repo.appending(path: "packages"), name: "web",
                        folder: "node_modules", sibling: "package.json", idle: 200)
        try fm.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        let index = repo.appending(path: ".git/index")
        try "x".write(to: index, atomically: true, encoding: .utf8)
        try setDate(index, daysAgo(2))

        #expect(ProjectScan.scan(roots: [root], olderThanDays: 30).items.isEmpty)
    }

    @Test("Skips a folder that changed in the last 24 hours even when the manifest is old")
    func recentlyModifiedFolderSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json", idle: 200)
        // Someone just ran npm install.
        try setDate(target, Date())

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(r.items.isEmpty)
        #expect(r.skippedRecent == 1)
    }

    @Test("Skips a folder whose contents changed in the last 24 hours")
    func recentlyModifiedChildSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json", idle: 200)
        try setDate(target.appending(path: "pkg"), Date().addingTimeInterval(-3600))

        #expect(ProjectScan.scan(roots: [root], olderThanDays: 30).skippedRecent == 1)
    }
}

@Suite("Projects: moving to the Trash")
struct ProjectTrashTests {

    /// Moves into a temp "trash" folder, standing in for the real Trash.
    private func fakeTrash(_ dir: URL, moved: Box) -> (URL) throws -> Void {
        { url in
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: dir.appending(path: UUID().uuidString))
            moved.urls.append(url)
        }
    }
    final class Box { var urls: [URL] = [] }

    @Test("A verified folder is moved, and only that folder")
    func movesVerifiedFolder() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        let scan = ProjectScan.scan(roots: [root], olderThanDays: 30)

        let box = Box()
        let r = ProjectScan.moveToTrash(scan.items, roots: [root], olderThanDays: 30,
                                        trash: fakeTrash(root.appending(path: ".fake-trash"), moved: box))

        #expect(r.moved == 1)
        #expect(r.bytes == scan.items.first?.bytes)
        #expect(!fm.fileExists(atPath: target.path))
        // The manifest and the project itself are untouched.
        #expect(fm.fileExists(atPath: target.deletingLastPathComponent().appending(path: "package.json").path))
    }

    /// The classic way a cleaner destroys data: the path is swapped for a link
    /// to something precious between the scan and the click.
    @Test("A folder replaced by a symlink to outside the roots is never trashed")
    func symlinkSwappedInAfterScan() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let outside = try makeRoot(); defer { try? fm.removeItem(at: outside) }
        let precious = outside.appending(path: "thesis")
        try fm.createDirectory(at: precious, withIntermediateDirectories: true)
        try "irreplaceable".write(to: precious.appending(path: "chapter1.txt"), atomically: true, encoding: .utf8)

        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        let scan = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(scan.items.count == 1)

        try fm.removeItem(at: target)
        try fm.createSymbolicLink(at: target, withDestinationURL: precious)

        let box = Box()
        let r = ProjectScan.moveToTrash(scan.items, roots: [root], olderThanDays: 30,
                                        trash: fakeTrash(outside.appending(path: "trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.refused.count == 1)
        #expect(box.urls.isEmpty)
        #expect(fm.fileExists(atPath: precious.appending(path: "chapter1.txt").path))
    }

    @Test("A path that passes through a symlink out of the roots is refused")
    func intermediateSymlinkRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let outside = try makeRoot(); defer { try? fm.removeItem(at: outside) }
        let real = try makeProject(in: outside, folder: "node_modules", sibling: "package.json")
        let link = root.appending(path: "linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        // Spelled as inside the root, lands outside it.
        let item = ProjectItem(url: link.appending(path: "app/node_modules"), kind: .node, bytes: 1,
                               sizeCapped: false, lastActive: daysAgo(90), idleDays: 90)
        let box = Box()
        let r = ProjectScan.moveToTrash([item], roots: [root], olderThanDays: 30,
                                        trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.refused.count == 1)
        #expect(fm.fileExists(atPath: real.path))
    }

    @Test("A real folder outside every root is refused")
    func outsideRootsRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let outside = try makeRoot(); defer { try? fm.removeItem(at: outside) }
        let target = try makeProject(in: outside, folder: "node_modules", sibling: "package.json")
        let item = ProjectItem(url: target, kind: .node, bytes: 1, sizeCapped: false,
                               lastActive: daysAgo(90), idleDays: 90)

        let box = Box()
        let r = ProjectScan.moveToTrash([item], roots: [root], olderThanDays: 30,
                                        trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.refused.count == 1)
        #expect(fm.fileExists(atPath: target.path))
    }

    @Test("A folder whose manifest has gone is refused")
    func manifestRemovedAfterScan() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        let scan = ProjectScan.scan(roots: [root], olderThanDays: 30)
        try fm.removeItem(at: root.appending(path: "app/package.json"))

        let box = Box()
        let r = ProjectScan.moveToTrash(scan.items, roots: [root], olderThanDays: 30,
                                        trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.refused.count == 1)
        #expect(fm.fileExists(atPath: target.path))
    }

    @Test("A project touched after the scan is skipped and reported")
    func touchedAfterScanIsSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        let scan = ProjectScan.scan(roots: [root], olderThanDays: 30)
        #expect(scan.items.count == 1)

        // The user opened the project and edited the manifest.
        try setDate(root.appending(path: "app/package.json"), Date())

        let box = Box()
        let r = ProjectScan.moveToTrash(scan.items, roots: [root], olderThanDays: 30,
                                        trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.skippedRecent.count == 1)
        #expect(fm.fileExists(atPath: target.path))
    }

    @Test("A folder modified in the last 24 hours after the scan is skipped")
    func folderTouchedAfterScanIsSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        let scan = ProjectScan.scan(roots: [root], olderThanDays: 30)
        try setDate(target, Date())

        let box = Box()
        let r = ProjectScan.moveToTrash(scan.items, roots: [root], olderThanDays: 30,
                                        trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.skippedRecent.count == 1)
        #expect(box.urls.isEmpty)
    }

    @Test("A failing Trash call is reported, not counted as moved")
    func trashFailureReported() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        let scan = ProjectScan.scan(roots: [root], olderThanDays: 30)

        struct Busy: Error {}
        let r = ProjectScan.moveToTrash(scan.items, roots: [root], olderThanDays: 30) { _ in throw Busy() }
        #expect(r.moved == 0)
        #expect(r.bytes == 0)
        #expect(r.failed.count == 1)
        #expect(fm.fileExists(atPath: target.path))
    }
}

@Suite("Projects: roots and limits")
struct ProjectRootTests {

    @Test("Only the default folders that exist are scanned, and never Documents, Desktop, Downloads or Library")
    func defaultRoots() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        for n in ["Developer", "code", "Documents", "Desktop", "Downloads", "Library"] {
            try fm.createDirectory(at: home.appending(path: n), withIntermediateDirectories: true)
        }
        let names = ProjectScan.roots(home: home).map(\.lastPathComponent)
        #expect(names == ["Developer", "code"])
    }

    @Test("A folder the user added is included once, however it is spelled")
    func addedRoot() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        let extra = home.appending(path: "elsewhere/stuff")
        try fm.createDirectory(at: extra, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Developer"), withIntermediateDirectories: true)

        let roots = ProjectScan.roots(extra: [extra.path, extra.path, extra.path + "/"], home: home)
        #expect(roots.map(\.lastPathComponent) == ["Developer", "stuff"])
    }

    @Test("Too-broad folders are refused as roots")
    func broadRootsRefused() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appending(path: "Library/Caches"), withIntermediateDirectories: true)
        #expect(!ProjectScan.isAcceptableRoot(URL(fileURLWithPath: "/"), home: home))
        #expect(!ProjectScan.isAcceptableRoot(home, home: home))
        #expect(!ProjectScan.isAcceptableRoot(home.appending(path: "Library"), home: home))
        #expect(!ProjectScan.isAcceptableRoot(home.appending(path: "Library/Caches"), home: home))
        #expect(!ProjectScan.isAcceptableRoot(URL(fileURLWithPath: "/System"), home: home))
        #expect(!ProjectScan.isAcceptableRoot(URL(fileURLWithPath: "/Applications"), home: home))
    }

    @Test("A string-prefix sibling is not treated as inside a root")
    func prefixSiblingNotInside() {
        #expect(!ProjectScan.isInside(URL(fileURLWithPath: "/a/proj-evil/x"), of: URL(fileURLWithPath: "/a/proj")))
        #expect(ProjectScan.isInside(URL(fileURLWithPath: "/a/proj/x"), of: URL(fileURLWithPath: "/a/proj")))
        #expect(!ProjectScan.isInside(URL(fileURLWithPath: "/a/proj"), of: URL(fileURLWithPath: "/a/proj")))
    }

    @Test("The walk stops at its entry cap and says so")
    func entryCap() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        for i in 0..<20 {
            try fm.createDirectory(at: root.appending(path: "dir\(i)/sub"), withIntermediateDirectories: true)
        }
        let r = ProjectScan.scan(roots: [root], olderThanDays: 30, maxEntries: 5)
        #expect(r.capped)
    }

    @Test("A small tree is not reported as capped")
    func notCappedWhenSmall() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        #expect(!ProjectScan.scan(roots: [root], olderThanDays: 30).capped)
    }

    @Test("Sizing marks a folder as a lower bound when it hits its cap")
    func sizeCap() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeProject(in: root, folder: "node_modules", sibling: "package.json")
        for i in 0..<30 {
            try Data(repeating: 1, count: 4096).write(to: target.appending(path: "f\(i).bin"))
        }
        try age(target, days: 90)

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30, sizeEntryCap: 10)
        #expect(r.capped)
        #expect(r.items.first?.sizeCapped == true)
    }

    @Test("Cancelling returns promptly with nothing listed")
    func cancellation() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeProject(in: root, folder: "node_modules", sibling: "package.json")

        let r = ProjectScan.scan(roots: [root], olderThanDays: 30, isCancelled: { true })
        #expect(r.cancelled)
        #expect(r.items.isEmpty)
    }

    @Test("Finds projects that sit directly in the home folder, and never opens the private ones")
    func homeProjects() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        for name in ["myapp", "Desktop", "plain"] {
            try fm.createDirectory(at: home.appending(path: name), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: home.appending(path: "myapp/.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Desktop/.git"), withIntermediateDirectories: true)

        let names = ProjectScan.roots(home: home).map(\.lastPathComponent)
        #expect(names.contains("myapp"))
        #expect(!names.contains("Desktop"))
        #expect(!names.contains("plain"))
    }
}
