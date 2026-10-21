import Testing
import Foundation
@testable import BoostKit

// All of these run against temporary directories with a tiny size threshold, so
// they stay fast. None of them touches the real Trash: moves go through an
// injected closure.

private var fm: FileManager { .default }
private let kb = 1024
/// Files in these tests are 300 KB or 20 KB; the threshold sits between.
private let threshold: UInt64 = 100 * 1024

/// A fresh temp directory, already symlink-resolved (/var is /private/var on
/// macOS, and the scanner compares resolved paths).
private func makeRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "boost-large-\(UUID().uuidString)")
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return ProjectScan.canonical(url)
}

private func daysAgo(_ n: Int) -> Date { Date().addingTimeInterval(-Double(n) * 86_400) }

private func setDate(_ url: URL, _ date: Date) throws {
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

/// Writes a file of `size` KB, back-dated so it is not "recent".
@discardableResult
private func makeFile(_ url: URL, kbSize: Int = 300, ageDays: Int = 30) throws -> URL {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: kbSize * kb).write(to: url)
    try setDate(url, daysAgo(ageDays))
    return url
}

private func paths(_ r: LargeFileScanResult) -> [String] { r.items.map(\.url.path) }

private func scan(_ root: URL, min: UInt64 = threshold, limit: Int = 200,
                  maxEntries: Int = 100_000) -> LargeFileScanResult {
    LargeFileScan.scan(roots: LargeFileRoots(deep: [root]), minBytes: min, limit: limit, maxEntries: maxEntries)
}

@Suite("Large files: what is listed")
struct LargeFileDetectionTests {

    @Test("Finds files over the threshold and ignores smaller ones")
    func thresholdRespected() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let big = try makeFile(root.appending(path: "movie.mov"), kbSize: 300)
        try makeFile(root.appending(path: "note.txt"), kbSize: 20)

        let r = scan(root)
        #expect(paths(r) == [big.path])
        #expect(r.matches == 1)
    }

    @Test("Looks inside ordinary subfolders")
    func recursesIntoFolders() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let deep = try makeFile(root.appending(path: "a/b/c/video.mp4"))

        #expect(paths(scan(root)) == [deep.path])
    }

    @Test("Sorted by size, largest first")
    func sortedLargestFirst() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: "mid.bin"), kbSize: 300)
        try makeFile(root.appending(path: "big.bin"), kbSize: 900)
        try makeFile(root.appending(path: "small.bin"), kbSize: 150)

        #expect(scan(root).items.map(\.name) == ["big.bin", "mid.bin", "small.bin"])
    }

    @Test("Reports the size on disk, not an arbitrary number")
    func sizeReported() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: "f.bin"), kbSize: 512)

        let bytes = scan(root).items.first?.bytes ?? 0
        #expect(bytes >= 512 * 1024)
        #expect(bytes < 600 * 1024)
    }

    @Test("The list is capped at the limit and says how many matched")
    func capsAtLimit() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        for i in 0..<8 {
            try makeFile(root.appending(path: "f\(i).bin"), kbSize: 200 + i * 10)
        }

        let r = scan(root, limit: 3)
        #expect(r.items.count == 3)
        #expect(r.matches == 8)
        #expect(r.truncated)
        // The three kept are the three largest.
        #expect(r.items.map(\.name) == ["f7.bin", "f6.bin", "f5.bin"])
    }

    @Test("A list under the limit is not reported as truncated")
    func notTruncatedWhenSmall() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: "f.bin"))
        #expect(!scan(root, limit: 5).truncated)
    }

    @Test("Hidden files and hidden folders are skipped")
    func hiddenSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: ".secret.bin"))
        try makeFile(root.appending(path: ".cache/blob.bin"))
        try makeFile(root.appending(path: "visible/.hidden-inside.bin"))
        let shown = try makeFile(root.appending(path: "visible/shown.bin"))

        #expect(paths(scan(root)) == [shown.path])
    }

    @Test("A big file inside an app or a library bundle is not listed", arguments: [
        "Foo.app/Contents/MacOS/Foo",
        "Photos.photoslibrary/originals/IMG_1.heic",
        "Songs.musiclibrary/Media/track.m4a",
        "Movie.imovielibrary/Event/clip.mov",
        "Cut.fcpbundle/Project/render.mov",
        "Build.xcarchive/Products/App",
        "Thing.framework/Versions/A/Thing",
    ])
    func bundleContentsSkipped(inside: String) throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: inside))
        let outside = try makeFile(root.appending(path: "plain/big.bin"))

        #expect(paths(scan(root)) == [outside.path])
    }

    @Test("A bundle is skipped even when nothing registers its extension")
    func unknownBundleExtensionStillSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: "Old.PHOTOSLIBRARY/originals/a.heic"))

        #expect(scan(root).items.isEmpty)
    }

    @Test("A symlink to a big file elsewhere is not listed")
    func symlinkedFileIgnored() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let elsewhere = try makeRoot(); defer { try? fm.removeItem(at: elsewhere) }
        let target = try makeFile(elsewhere.appending(path: "huge.bin"), kbSize: 900)
        try fm.createSymbolicLink(at: root.appending(path: "link.bin"), withDestinationURL: target)

        #expect(scan(root).items.isEmpty)
    }

    @Test("A symlinked folder is not entered")
    func symlinkedFolderNotFollowed() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let elsewhere = try makeRoot(); defer { try? fm.removeItem(at: elsewhere) }
        try makeFile(elsewhere.appending(path: "big/huge.bin"), kbSize: 900)
        try fm.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: elsewhere.appending(path: "big"))

        #expect(scan(root).items.isEmpty)
    }

    @Test("A file that changed in the last minute is left out and counted")
    func recentSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: "downloading.bin"), ageDays: 0)
        let old = try makeFile(root.appending(path: "old.bin"))

        let r = scan(root)
        #expect(paths(r) == [old.path])
        #expect(r.skippedRecent == 1)
    }

    @Test("A file listed through two overlapping roots appears once")
    func overlappingRoots() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let f = try makeFile(root.appending(path: "work/f.bin"))

        let r = LargeFileScan.scan(roots: LargeFileRoots(deep: [root, root.appending(path: "work"), root]),
                                   minBytes: threshold)
        #expect(paths(r) == [f.path])
    }

    @Test("A shallow root lists its own files and nothing below them")
    func shallowRoot() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        let top = try makeFile(home.appending(path: "image.iso"))
        try makeFile(home.appending(path: "Library/Caches/blob.bin"))
        try makeFile(home.appending(path: "Stuff/inner.bin"))

        let r = LargeFileScan.scan(roots: LargeFileRoots(deep: [], shallow: [home]), minBytes: threshold)
        #expect(paths(r) == [top.path])
    }

    @Test("The walk stops at its entry cap and says so")
    func entryCap() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        for i in 0..<20 { try makeFile(root.appending(path: "f\(i).bin"), kbSize: 1) }

        let r = scan(root, maxEntries: 5)
        #expect(r.capped)
        #expect(r.visited <= 6)
    }

    @Test("A small tree is not reported as capped")
    func notCappedWhenSmall() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: "f.bin"))
        #expect(!scan(root).capped)
    }

    @Test("Cancelling returns promptly with nothing listed")
    func cancellation() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        try makeFile(root.appending(path: "f.bin"))

        let r = LargeFileScan.scan(roots: LargeFileRoots(deep: [root]), minBytes: threshold, isCancelled: { true })
        #expect(r.cancelled)
        #expect(r.items.isEmpty)
    }
}

@Suite("Large files: ordering and wording")
struct LargeFileOrderingTests {

    private func item(_ name: String, bytes: UInt64 = 1, used: Int? = nil, accessed: Bool = true) -> LargeFileItem {
        let date = used.map { daysAgo($0) }
        return LargeFileItem(url: URL(fileURLWithPath: "/x/\(name)"), bytes: bytes,
                             lastAccessed: accessed ? date : nil, lastModified: date)
    }

    @Test("Oldest first puts the longest unused file at the top and unknown dates last")
    func ageOrder() {
        let items = [item("new", used: 5), item("none"), item("old", used: 400), item("mid", used: 90)]
        #expect(LargeFileScan.sorted(items, by: .age).map(\.name) == ["old", "mid", "new", "none"])
    }

    @Test("Name order is natural, not byte order")
    func nameOrder() {
        let items = [item("file10.bin"), item("File2.bin"), item("alpha.bin")]
        #expect(LargeFileScan.sorted(items, by: .name).map(\.name) == ["alpha.bin", "File2.bin", "file10.bin"])
    }

    @Test("Size order is largest first")
    func sizeOrder() {
        let items = [item("a", bytes: 1), item("b", bytes: 3), item("c", bytes: 2)]
        #expect(LargeFileScan.sorted(items, by: .size).map(\.name) == ["b", "c", "a"])
    }

    @Test("Age text says opened when an access date is known, modified when it is not")
    func ageText() {
        // An hour of slack, because the items are dated a moment after this line.
        let now = Date().addingTimeInterval(3600)
        #expect(LargeFileScan.ageText(for: item("a", used: 240), now: now) == "Not opened for 8 months")
        #expect(LargeFileScan.ageText(for: item("a", used: 12), now: now) == "Not opened for 12 days")
        #expect(LargeFileScan.ageText(for: item("a", used: 1), now: now) == "Not opened for 1 day")
        #expect(LargeFileScan.ageText(for: item("a", used: 800), now: now) == "Not opened for 2 years")
        #expect(LargeFileScan.ageText(for: item("a", used: 240, accessed: false), now: now) == "Modified 8 months ago")
        #expect(LargeFileScan.ageText(for: item("a", used: 0, accessed: false), now: now) == "Modified today")
        #expect(LargeFileScan.ageText(for: item("a"), now: now) == "Date unknown")
    }

    @Test("A recent edit counts as use even when the access date is old")
    func modifiedCountsAsUse() {
        let i = LargeFileItem(url: URL(fileURLWithPath: "/x/a"), bytes: 1,
                              lastAccessed: daysAgo(400), lastModified: daysAgo(3))
        #expect(LargeFileScan.ageText(for: i) == "Not opened for 3 days")
    }
}

@Suite("Large files: moving to the Trash")
struct LargeFileTrashTests {

    /// Moves into a temp "trash" folder, standing in for the real Trash.
    private func fakeTrash(_ dir: URL, moved: Box) -> (URL) throws -> Void {
        { url in
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: dir.appending(path: UUID().uuidString))
            moved.urls.append(url)
        }
    }
    final class Box { var urls: [URL] = [] }

    private func item(_ url: URL, bytes: UInt64 = 1, modified: Date? = nil) -> LargeFileItem {
        LargeFileItem(url: url, bytes: bytes, lastAccessed: nil, lastModified: modified ?? daysAgo(30))
    }

    @Test("A verified file is moved through the injected closure, and its bytes are reported")
    func movesVerifiedFile() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeFile(root.appending(path: "movie.mov"))
        let neighbour = try makeFile(root.appending(path: "keep.mov"))
        let found = scan(root).items.filter { $0.url.path == target.path }

        let box = Box()
        let r = LargeFileScan.moveToTrash(found, roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(root.appending(path: ".fake-trash"), moved: box))
        #expect(r.moved == 1)
        #expect(r.bytes == found.first?.bytes)
        #expect(r.bytes > 0)
        #expect(r.movedPaths == [target.path])
        #expect(!fm.fileExists(atPath: target.path))
        #expect(fm.fileExists(atPath: neighbour.path))
    }

    @Test("A file outside every root is refused")
    func outsideRootsRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let outside = try makeRoot(); defer { try? fm.removeItem(at: outside) }
        let target = try makeFile(outside.appending(path: "f.bin"))

        let box = Box()
        let r = LargeFileScan.moveToTrash([item(target)], roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.refused.count == 1)
        #expect(box.urls.isEmpty)
        #expect(fm.fileExists(atPath: target.path))
    }

    @Test("A string-prefix sibling of a root is not inside it")
    func prefixSiblingRefused() throws {
        let base = try makeRoot(); defer { try? fm.removeItem(at: base) }
        let root = base.appending(path: "proj")
        let evil = base.appending(path: "proj-evil")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = try makeFile(evil.appending(path: "f.bin"))

        let box = Box()
        let r = LargeFileScan.moveToTrash([item(target)], roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(base.appending(path: "trash"), moved: box))
        #expect(r.refused.count == 1)
        #expect(box.urls.isEmpty)
        #expect(fm.fileExists(atPath: target.path))

        // The same check, without touching the disk.
        #expect(LargeFileScan.rootContaining(URL(fileURLWithPath: "/a/proj-evil/x"),
                                             in: LargeFileRoots(deep: [URL(fileURLWithPath: "/a/proj")])) == nil)
        #expect(LargeFileScan.rootContaining(URL(fileURLWithPath: "/a/proj/x"),
                                             in: LargeFileRoots(deep: [URL(fileURLWithPath: "/a/proj")])) != nil)
    }

    /// The classic way a cleaner destroys data: the path is swapped for a link
    /// to something precious between the scan and the click.
    @Test("A file replaced by a symlink after the scan is never trashed")
    func symlinkSwappedInAfterScan() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let outside = try makeRoot(); defer { try? fm.removeItem(at: outside) }
        let precious = try makeFile(outside.appending(path: "thesis.docx"))

        let target = try makeFile(root.appending(path: "movie.mov"))
        let found = scan(root).items
        #expect(found.count == 1)

        try fm.removeItem(at: target)
        try fm.createSymbolicLink(at: target, withDestinationURL: precious)

        let box = Box()
        let r = LargeFileScan.moveToTrash(found, roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(outside.appending(path: "trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.refused.count == 1)
        #expect(box.urls.isEmpty)
        #expect(fm.fileExists(atPath: precious.path))
    }

    @Test("A symlink to a file inside the roots is refused too, because it is a link")
    func symlinkInsideRootsRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let real = try makeFile(root.appending(path: "real.bin"))
        let link = root.appending(path: "link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let box = Box()
        let r = LargeFileScan.moveToTrash([item(link)], roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.refused.count == 1)
        #expect(box.urls.isEmpty)
        #expect(fm.fileExists(atPath: real.path))
    }

    @Test("A path that passes through a symlinked folder is refused")
    func intermediateSymlinkRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let outside = try makeRoot(); defer { try? fm.removeItem(at: outside) }
        let real = try makeFile(outside.appending(path: "dir/f.bin"))
        try fm.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: outside)

        // Spelled as inside the root, lands outside it.
        let spelled = root.appending(path: "linked/dir/f.bin")
        let box = Box()
        let r = LargeFileScan.moveToTrash([item(spelled)], roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.refused.count == 1)
        #expect(fm.fileExists(atPath: real.path))
    }

    @Test("A folder is never trashed from this tab")
    func directoryRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let dir = root.appending(path: "Projects")
        try makeFile(dir.appending(path: "f.bin"))

        let box = Box()
        let r = LargeFileScan.moveToTrash([item(dir)], roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(root.appending(path: ".trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.refused.count == 1)
        #expect(box.urls.isEmpty)
        #expect(fm.fileExists(atPath: dir.path))
    }

    @Test("A file modified in the last 60 seconds is skipped and reported")
    func recentlyModifiedSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeFile(root.appending(path: "f.bin"))
        let found = scan(root).items
        #expect(found.count == 1)

        // Saved after the scan.
        try setDate(target, Date().addingTimeInterval(-10))

        let box = Box()
        let r = LargeFileScan.moveToTrash(found, roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(root.appending(path: ".trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.skippedRecent == [target.path])
        #expect(box.urls.isEmpty)
        #expect(fm.fileExists(atPath: target.path))
    }

    @Test("A file whose date is in the future is skipped")
    func futureDateSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeFile(root.appending(path: "f.bin"))
        try setDate(target, Date().addingTimeInterval(3600))

        let r = LargeFileScan.moveToTrash([item(target, modified: Date().addingTimeInterval(3600))],
                                          roots: LargeFileRoots(deep: [root]), trash: { _ in })
        #expect(r.skippedRecent.count == 1)
    }

    @Test("A file saved over since the scan is skipped, even if the save was not recent")
    func changedSinceScanSkipped() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeFile(root.appending(path: "f.bin"), ageDays: 30)
        let found = scan(root).items

        try setDate(target, daysAgo(5))

        let r = LargeFileScan.moveToTrash(found, roots: LargeFileRoots(deep: [root]), trash: { _ in })
        #expect(r.moved == 0)
        #expect(r.skippedRecent.count == 1)
    }

    @Test("A file inside a bundle or a hidden folder is refused")
    func bundleAndHiddenRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let inApp = try makeFile(root.appending(path: "Foo.app/Contents/big.bin"))
        let inHidden = try makeFile(root.appending(path: ".cache/big.bin"))
        let hiddenFile = try makeFile(root.appending(path: ".big.bin"))

        let box = Box()
        let r = LargeFileScan.moveToTrash([item(inApp), item(inHidden), item(hiddenFile)],
                                          roots: LargeFileRoots(deep: [root]),
                                          trash: fakeTrash(root.appending(path: "trash"), moved: box))
        #expect(r.moved == 0)
        #expect(r.refused.count == 3)
        #expect(box.urls.isEmpty)
    }

    @Test("A file directly in a shallow root is allowed, one below it is not")
    func shallowRootRules() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        let top = try makeFile(home.appending(path: "image.iso"))
        let below = try makeFile(home.appending(path: "Library/Caches/blob.bin"))

        let box = Box()
        let r = LargeFileScan.moveToTrash([item(top), item(below)],
                                          roots: LargeFileRoots(deep: [], shallow: [home]),
                                          trash: fakeTrash(home.appending(path: ".trash"), moved: box))
        #expect(r.movedPaths == [top.path])
        #expect(r.refused == [below.path])
        #expect(fm.fileExists(atPath: below.path))
    }

    @Test("A file that has gone is refused, not counted")
    func missingRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let r = LargeFileScan.moveToTrash([item(root.appending(path: "nope.bin"))],
                                          roots: LargeFileRoots(deep: [root]), trash: { _ in })
        #expect(r.moved == 0)
        #expect(r.refused.count == 1)
    }

    @Test("A failing Trash call is reported, not counted as moved")
    func trashFailureReported() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let target = try makeFile(root.appending(path: "f.bin"))
        let found = scan(root).items

        struct Busy: Error {}
        let r = LargeFileScan.moveToTrash(found, roots: LargeFileRoots(deep: [root])) { _ in throw Busy() }
        #expect(r.moved == 0)
        #expect(r.bytes == 0)
        #expect(r.failed == [target.path])
        #expect(fm.fileExists(atPath: target.path))
    }
}

@Suite("Large files: roots")
struct LargeFileRootTests {

    @Test("Only the six personal folders that exist are scanned, plus the home folder's own files")
    func defaultRoots() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        for n in ["Downloads", "Documents", "Movies", "Library", "Applications", "Developer", "Public"] {
            try fm.createDirectory(at: home.appending(path: n), withIntermediateDirectories: true)
        }
        let roots = LargeFileScan.roots(home: home)
        #expect(roots.deep.map(\.lastPathComponent) == ["Downloads", "Documents", "Movies"])
        #expect(roots.shallow == [home])
    }

    @Test("A personal folder that is really a link into Library is not scanned")
    func linkIntoLibraryRefused() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appending(path: "Library/Mobile Documents"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: "Documents"),
                                  withDestinationURL: home.appending(path: "Library/Mobile Documents"))

        #expect(LargeFileScan.roots(home: home).deep.isEmpty)
    }

    @Test("Other volumes and system folders are never roots")
    func broadRootsRefused() throws {
        let home = try makeRoot(); defer { try? fm.removeItem(at: home) }
        #expect(!LargeFileScan.isAcceptableRoot(URL(fileURLWithPath: "/Volumes/Backup/Movies"), home: home))
        #expect(!LargeFileScan.isAcceptableRoot(URL(fileURLWithPath: "/System"), home: home))
        #expect(!LargeFileScan.isAcceptableRoot(URL(fileURLWithPath: "/Applications"), home: home))
        #expect(!LargeFileScan.isAcceptableRoot(home.appending(path: "Library"), home: home))
        #expect(!LargeFileScan.isAcceptableRoot(home, home: home))
    }
}
