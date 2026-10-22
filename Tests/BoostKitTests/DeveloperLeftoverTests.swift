import Testing
import Foundation
@testable import BoostKit

/// Fixtures live in a throwaway home directory, so nothing here reads or
/// removes anything on the machine running the tests.
@Suite("Developer leftovers")
struct DeveloperLeftoverTests {

    /// A fake home. Callers remove `root` when done.
    private struct Fixture {
        let root: URL
        let home: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "boost-dev-\(UUID().uuidString)")
            home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func make(_ relative: String, bytes: Int = 0) throws {
            let dir = home.appending(path: relative)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if bytes > 0 {
                try Data(repeating: 1, count: bytes).write(to: dir.appending(path: "blob.bin"))
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func ids(_ targets: [CleanupTarget]) -> Set<String> { Set(targets.map(\.id)) }

    private func thesisSurvives(_ f: Fixture) -> Bool {
        FileManager.default.fileExists(atPath: f.home.appending(path: "Documents/thesis/blob.bin").path)
    }

    // MARK: Found when present, ignored when absent

    @Test("Every new target is ignored when its folder is missing")
    func absentIsSilent() throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(DiskScan.scan(home: f.home).isEmpty)
        #expect(DiskScan.dockerImage(home: f.home) == nil)
    }

    @Test("Device support folders are found and their sizes add up")
    func deviceSupportFoundAndSummed() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Library/Developer/Xcode/iOS DeviceSupport/17.0", bytes: 256 * 1024)
        try f.make("Library/Developer/Xcode/watchOS DeviceSupport/10.0", bytes: 128 * 1024)
        try f.make("Library/Developer/Xcode/tvOS DeviceSupport/17.0", bytes: 64 * 1024)
        try f.make("Library/Developer/Xcode/visionOS DeviceSupport/1.0", bytes: 64 * 1024)

        let t = try #require(DiskScan.scan(home: f.home).first { $0.id == "device-support" })
        let expected = t.paths.reduce(UInt64(0)) { $0 + DiskScan.size(of: $1) }
        #expect(t.bytes == expected)
        #expect(t.bytes >= 512 * 1024)
        #expect(t.regenerates)
        #expect(!t.userData)
        #expect(t.detail.contains("few minutes"))
    }

    @Test("One missing platform folder does not hide the others")
    func partialDeviceSupport() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Library/Developer/Xcode/iOS DeviceSupport/16.4", bytes: 100 * 1024)
        let t = try #require(DiskScan.scan(home: f.home).first { $0.id == "device-support" })
        #expect(t.bytes == DiskScan.size(of: f.home.appending(path: "Library/Developer/Xcode/iOS DeviceSupport")))
    }

    @Test("The SwiftPM cache is found when present and skipped when absent")
    func swiftpmFound() throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(!ids(DiskScan.scan(home: f.home)).contains("swiftpm"))
        try f.make(".swiftpm/cache/repositories", bytes: 96 * 1024)
        let t = try #require(DiskScan.scan(home: f.home).first { $0.id == "swiftpm" })
        #expect(t.bytes >= 96 * 1024)
        #expect(t.regenerates)
    }

    @Test("Archives are found, flagged as user data and not regenerable")
    func archivesFound() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Library/Developer/Xcode/Archives/2025-01-01/App.xcarchive", bytes: 200 * 1024)
        let t = try #require(DiskScan.scan(home: f.home).first { $0.id == "xcode-archives" })
        #expect(t.userData)
        #expect(!t.regenerates)
        #expect(t.bytes >= 200 * 1024)
        #expect(t.detail == "Archives of apps you built. They hold the debug symbols you need to "
                          + "read crash reports from released builds. Remove only ones you no "
                          + "longer ship.")
    }

    @Test("Nothing is duplicated, and SwiftPM, Carthage and simulator caches are already covered")
    func noDuplicates() {
        let h = URL(fileURLWithPath: "/Users/tester")
        let all = DiskScan.targets(home: h).flatMap { $0.paths.map(\.path) }
        #expect(all.count == Set(all).count)

        // Covered by "Application caches" (all of ~/Library/Caches) and by the
        // simulator row, so there is deliberately no second row for them.
        let caches = h.appending(path: "Library/Caches").path
        #expect(all.contains(caches))
        for name in ["org.swift.swiftpm", "Carthage"] {
            #expect(!all.contains(caches + "/" + name))
            #expect(DiskScan.isSafeToDelete(h.appending(path: "Library/Caches/" + name), home: h))
        }
        let sim = all.filter { $0.contains("CoreSimulator") }
        #expect(sim == ["/Users/tester/Library/Developer/CoreSimulator/Caches"])
    }

    @Test("Archives are listed last, even when other rows are found")
    func archivesListedLast() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Library/Developer/Xcode/Archives/2025-01-01", bytes: 64 * 1024)
        try f.make("Library/Logs/App", bytes: 64 * 1024)
        try f.make(".swiftpm/cache", bytes: 64 * 1024)
        try f.make("Library/Developer/Xcode/iOS DeviceSupport/17.0", bytes: 64 * 1024)
        let found = DiskScan.scan(home: f.home)
        #expect(found.count >= 4)
        #expect(found.last?.id == "xcode-archives")
        #expect(DiskScan.targets(home: f.home).last?.id == "xcode-archives")
    }

    // MARK: Guards

    @Test("Every new target passes its own guard")
    func newTargetsPassGuard() {
        for t in DiskScan.targets() where ["device-support", "swiftpm", "xcode-archives"].contains(t.id) {
            for p in t.paths { #expect(DiskScan.isSafeToDelete(p), "\(p.path)") }
        }
    }

    @Test("The recheck refuses a path outside the allowlist")
    func recheckRefusesOutsideAllowlist() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Documents/thesis", bytes: 32 * 1024)
        let rogue = CleanupTarget(id: "rogue", name: "Rogue", detail: "",
                                  paths: [f.home.appending(path: "Documents")],
                                  regenerates: true)
        let result = DiskScan.clean([rogue], home: f.home)
        #expect(result.removed == 0)
        #expect(result.refused.count == 1)
        #expect(thesisSurvives(f))
    }

    @Test("The recheck refuses a symlink swapped in for the folder after the scan")
    func recheckRefusesSwappedRoot() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Library/Developer/Xcode/iOS DeviceSupport/17.0", bytes: 64 * 1024)
        try f.make("Documents/thesis", bytes: 32 * 1024)
        let scanned = try #require(DiskScan.scan(home: f.home).first { $0.id == "device-support" })

        // After the scan, the folder becomes a link into Documents.
        let fm = FileManager.default
        let root = f.home.appending(path: "Library/Developer/Xcode/iOS DeviceSupport")
        try fm.removeItem(at: root)
        try fm.createSymbolicLink(at: root, withDestinationURL: f.home.appending(path: "Documents"))

        let result = DiskScan.clean([scanned], home: f.home)
        #expect(result.removed == 0)
        #expect(result.refused.contains(root.path))
        #expect(thesisSurvives(f))
    }

    @Test("The recheck refuses a symlink swapped in for an Archives entry")
    func recheckRefusesSwappedChild() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Library/Developer/Xcode/Archives/2025-01-01", bytes: 64 * 1024)
        try f.make("Documents/thesis", bytes: 32 * 1024)
        let scanned = try #require(DiskScan.scan(home: f.home).first { $0.id == "xcode-archives" })

        let fm = FileManager.default
        let child = f.home.appending(path: "Library/Developer/Xcode/Archives/2025-01-01")
        try fm.removeItem(at: child)
        try fm.createSymbolicLink(at: child, withDestinationURL: f.home.appending(path: "Documents"))

        let result = DiskScan.clean([scanned], home: f.home)
        #expect(result.removed == 0)
        // Listing a directory spells the path as /private/var, so compare the tail.
        #expect(result.refused.count == 1)
        #expect(result.refused.first?.hasSuffix("Xcode/Archives/2025-01-01") == true)
        #expect(thesisSurvives(f))
    }

    @Test("A genuine device support folder is emptied and the folder itself stays")
    func cleansDeviceSupport() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make("Library/Developer/Xcode/iOS DeviceSupport/17.0", bytes: 64 * 1024)
        let scanned = try #require(DiskScan.scan(home: f.home).first { $0.id == "device-support" })
        let result = DiskScan.clean([scanned], home: f.home)
        let root = f.home.appending(path: "Library/Developer/Xcode/iOS DeviceSupport")
        #expect(result.removed == 1)
        #expect(result.refused.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    // MARK: Archives are opt-in

    @Test("Select all never includes user data")
    func selectAllSkipsArchives() {
        let cache = CleanupTarget(id: "cache", name: "Cache", detail: "", paths: [], regenerates: true, bytes: 10)
        let archives = CleanupTarget(id: "xcode-archives", name: "Archives", detail: "", paths: [],
                                     regenerates: false, userData: true, bytes: 10)
        #expect(DiskScan.selectableIDs([cache, archives]) == ["cache"])
    }

    @MainActor
    @Test("The engine starts unticked, Select all skips Archives, Select none clears them")
    func engineSelection() {
        let cache = CleanupTarget(id: "cache", name: "Cache", detail: "", paths: [], regenerates: true, bytes: 100)
        let archives = CleanupTarget(id: "xcode-archives", name: "Archives", detail: "", paths: [],
                                     regenerates: false, userData: true, bytes: 900)
        let engine = DiskEngine(targets: [cache, archives])
        #expect(engine.selection.isEmpty)
        #expect(!engine.allSafeSelected)

        engine.setAll(true)
        #expect(engine.selection == ["cache"])
        #expect(engine.allSafeSelected)
        #expect(engine.selectedBytes == 100)

        // Ticking Archives by hand is allowed, and Select all keeps it.
        engine.toggle(archives)
        #expect(engine.selection == ["cache", "xcode-archives"])

        engine.setAll(false)
        #expect(engine.selection.isEmpty)

        // The headline counts caches only.
        #expect(engine.totalBytes == 100)
    }

    @MainActor
    @Test("Select all ticks nothing when only Archives exist")
    func onlyArchives() {
        let archives = CleanupTarget(id: "xcode-archives", name: "Archives", detail: "", paths: [],
                                     regenerates: false, userData: true, bytes: 900)
        let engine = DiskEngine(targets: [archives])
        engine.setAll(true)
        #expect(engine.selection.isEmpty)
        #expect(!engine.allSafeSelected)
    }

    // MARK: Docker, information only

    private func dockerDir(_ f: Fixture) throws -> URL {
        let dir = f.home.appending(path: "Library/Containers/com.docker.docker/Data/vms/0/data")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Docker size is read from the file path alone")
    func dockerSizeFromFile() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data(repeating: 0, count: 300 * 1024).write(to: try dockerDir(f).appending(path: "Docker.raw"))
        let info = try #require(DiskScan.dockerImage(home: f.home))
        #expect(info.bytes == 300 * 1024)
        #expect(info.path.lastPathComponent == "Docker.raw")
    }

    @Test("Docker is found at the older qcow2 location too")
    func dockerQcow2() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data(repeating: 0, count: 10 * 1024).write(to: try dockerDir(f).appending(path: "Docker.qcow2"))
        #expect(DiskScan.dockerImage(home: f.home)?.bytes == 10 * 1024)
    }

    /// The folder holds only a file this code never names. A reader that listed
    /// the directory would find it; a stat of the known paths does not.
    @Test("Docker is not shown when only the folder exists, so nothing is enumerated")
    func dockerNotShownWithoutKnownFile() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data(repeating: 0, count: 10 * 1024).write(to: try dockerDir(f).appending(path: "something-else.img"))
        #expect(DiskScan.dockerImage(home: f.home) == nil)
    }

    @Test("A symlink or an empty file is not shown as the Docker image")
    func dockerIgnoresLinksAndEmpty() throws {
        let f = try Fixture(); defer { f.remove() }
        let fm = FileManager.default
        let dir = try dockerDir(f)
        let target = f.home.appending(path: "elsewhere.bin")
        try Data(repeating: 0, count: 64 * 1024).write(to: target)
        try fm.createSymbolicLink(at: dir.appending(path: "Docker.raw"), withDestinationURL: target)
        #expect(DiskScan.dockerImage(home: f.home) == nil)

        try fm.removeItem(at: dir.appending(path: "Docker.raw"))
        try Data().write(to: dir.appending(path: "Docker.raw"))
        #expect(DiskScan.dockerImage(home: f.home) == nil)
    }

    @Test("Docker's image is never in the allowlist and is never deleted")
    func dockerNeverDeleted() throws {
        let f = try Fixture(); defer { f.remove() }
        let dir = try dockerDir(f)
        let file = dir.appending(path: "Docker.raw")
        try Data(repeating: 0, count: 64 * 1024).write(to: file)

        #expect(!DiskScan.isSafeToDelete(file, home: f.home))
        #expect(!DiskScan.isSafeToDelete(dir, home: f.home))
        // A scan finds no cleanup row for it, and the file is untouched.
        #expect(DiskScan.scan(home: f.home).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(DiskScan.dockerPruneCommand == "docker system prune")
    }
}
