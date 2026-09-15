import Testing
import Foundation
@testable import BoostKit

/// This is the suite that matters most in the project. Everything else here
/// fails visibly; a path bug in the cleaner fails by destroying something the
/// user cannot get back, and they find out later.
@Suite("Disk cleaner safety")
struct DiskScanSafetyTests {

    /// A fixed fake home, so these assertions do not depend on whose machine
    /// they run on.
    let home = URL(fileURLWithPath: "/Users/tester")

    private func safe(_ path: String) -> Bool {
        DiskScan.isSafeToDelete(URL(fileURLWithPath: path), home: home)
    }

    // MARK: - Things that must never be touched

    @Test("Refuses the home directory and everything directly in it", arguments: [
        "/Users/tester",
        "/Users/tester/Documents",
        "/Users/tester/Desktop",
        "/Users/tester/Downloads",
        "/Users/tester/Pictures",
        "/Users/tester/Library",
    ])
    func refusesTopLevel(path: String) {
        #expect(!safe(path))
    }

    @Test("Refuses anything outside the home directory", arguments: [
        "/",
        "/System",
        "/Applications",
        "/usr/local",
        "/Library/Caches",              // the *system* cache, not the user's
        "/Users/someone-else/Library/Caches",
        "/tmp",
    ])
    func refusesOutsideHome(path: String) {
        #expect(!safe(path))
    }

    @Test("Refuses user data that merely sits near a cache", arguments: [
        "/Users/tester/Library/Application Support",
        "/Users/tester/Library/Preferences",
        "/Users/tester/Library/Keychains",
        "/Users/tester/Library/Mail",
        "/Users/tester/Library/Messages",
        // Irreplaceable, and exactly what a careless "free up space" feature eats.
        "/Users/tester/Library/Application Support/MobileSync/Backup",
        "/Users/tester/Library/Developer/Xcode/Archives",
    ])
    func refusesUserData(path: String) {
        #expect(!safe(path))
    }

    @Test("Refuses a traversal back out of an allowed root", arguments: [
        "/Users/tester/Library/Caches/../../Documents",
        "/Users/tester/Library/Caches/../Preferences",
        "/Users/tester/.Trash/../Documents",
    ])
    func refusesTraversal(path: String) {
        #expect(!safe(path))
    }

    // MARK: - Things that must be allowed

    @Test("Allows the cache roots and their contents", arguments: [
        "/Users/tester/.Trash",
        "/Users/tester/.Trash/old-file.txt",
        "/Users/tester/Library/Caches",
        "/Users/tester/Library/Caches/com.some.app",
        "/Users/tester/Library/Caches/Homebrew/downloads/x.tar.gz",
        "/Users/tester/Library/Logs/SomeApp",
        "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc123",
        "/Users/tester/Library/Developer/CoreSimulator/Caches/dyld",
        "/Users/tester/.npm/_cacache/index-v5",
        "/Users/tester/.cache/uv/wheels",
        "/Users/tester/.cargo/registry/cache",
        "/Users/tester/.gradle/caches/modules-2",
    ])
    func allowsCaches(path: String) {
        #expect(safe(path))
    }

    /// `.cache` holds plenty besides uv, and none of the rest is ours to judge.
    @Test("Allows only the specific subdirectories claimed, not their parents", arguments: [
        "/Users/tester/.cache",
        "/Users/tester/.cache/some-other-tool",
        "/Users/tester/.cargo",
        "/Users/tester/.npm",
        "/Users/tester/.gradle",
        "/Users/tester/Library/Developer",
        "/Users/tester/Library/Developer/Xcode",
        "/Users/tester/Library/Developer/CoreSimulator",
    ])
    func refusesUnclaimedSiblings(path: String) {
        #expect(!safe(path))
    }

    // MARK: - Real filesystem behaviour

    /// A symlink inside a cache pointing at real data is the classic way this
    /// kind of tool destroys something. The check has to resolve before judging.
    @Test("A symlink out of a cache is judged by where it lands")
    func symlinkEscapeIsRefused() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "boost-symlink-test-\(UUID().uuidString)")
        let fakeHome = root.appending(path: "home")
        let caches = fakeHome.appending(path: "Library/Caches")
        let documents = fakeHome.appending(path: "Documents")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let precious = documents.appending(path: "thesis.txt")
        try "do not delete".write(to: precious, atomically: true, encoding: .utf8)

        let trap = caches.appending(path: "looks-like-cache")
        try fm.createSymbolicLink(at: trap, withDestinationURL: documents)

        // Spelled as a cache path, lands in Documents.
        #expect(!DiskScan.isSafeToDelete(trap, home: fakeHome))
        #expect(fm.fileExists(atPath: precious.path))
    }

    @Test("A real directory inside the cache is allowed")
    func genuineCacheIsAllowed() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "boost-cache-test-\(UUID().uuidString)")
        let fakeHome = root.appending(path: "home")
        let real = fakeHome.appending(path: "Library/Caches/com.example.app")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        #expect(DiskScan.isSafeToDelete(real, home: fakeHome))
    }
}

@Suite("Disk cleaner behaviour")
struct DiskScanBehaviourTests {

    @Test("A dry run reports a size and removes nothing")
    func dryRunRemovesNothing() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "boost-dry-\(UUID().uuidString)")
        let caches = root.appending(path: "Library/Caches/com.example.app")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let file = caches.appending(path: "blob.bin")
        try Data(repeating: 0, count: 64 * 1024).write(to: file)

        #expect(DiskScan.size(of: file) > 0)
        #expect(fm.fileExists(atPath: file.path))
    }

    @Test("Sizing skips symlinks rather than counting what they point at")
    func sizingDoesNotFollowSymlinks() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "boost-size-\(UUID().uuidString)")
        let dir = root.appending(path: "dir")
        let elsewhere = root.appending(path: "elsewhere")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(repeating: 0, count: 512 * 1024).write(to: elsewhere.appending(path: "big.bin"))
        try fm.createSymbolicLink(at: dir.appending(path: "link"), withDestinationURL: elsewhere)

        // The 512 KB lives outside `dir`; following the link would report it here.
        #expect(DiskScan.size(of: dir) < 256 * 1024)
    }

    @Test("Sizing a path that does not exist is zero, not a crash")
    func missingPathIsZero() {
        #expect(DiskScan.size(of: URL(fileURLWithPath: "/no/such/path/anywhere")) == 0)
    }

    @Test("Every advertised target is inside the allowlist it will be checked against")
    func everyTargetPassesItsOwnGuard() {
        for target in DiskScan.targets() {
            for path in target.paths {
                #expect(DiskScan.isSafeToDelete(path),
                        "target \(target.id) lists a path its own safety check refuses: \(path.path)")
            }
        }
    }
}
