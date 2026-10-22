import Testing
import Foundation
@testable import BoostKit

// All of these run against a temporary home folder. None of them touches the
// real Trash: moves go through an injected closure, and the few that need a
// file to really disappear delete it inside the temp folder.

private var fm: FileManager { .default }
private let kb = 1024

/// A fresh temp home, already symlink-resolved (/var is /private/var on macOS,
/// and the scanner compares resolved paths).
private func makeHome() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "boost-models-\(UUID().uuidString)")
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return ProjectScan.canonical(url)
}

private func daysAgo(_ n: Int) -> Date { Date().addingTimeInterval(-Double(n) * 86_400) }

private func setDate(_ url: URL, _ date: Date) throws {
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

/// Back-dates a folder and everything in it, so nothing in it looks recent.
/// Symlinks are left alone: setting a date on one would reach its target.
private func backdate(_ root: URL, days: Int = 30) throws {
    let date = daysAgo(days)
    if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            try setDate(url, date)
        }
    }
    try setDate(root, date)
}

@discardableResult
private func makeFile(_ url: URL, kbSize: Int = 64, ageDays: Int = 30) throws -> URL {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: kbSize * kb).write(to: url)
    try setDate(url, daysAgo(ageDays))
    return url
}

/// A 64 digit hex digest that is different for every `n`.
private func digest(_ n: Int) -> String { String(format: "%064x", n) }

private let ollamaRoot = ".ollama/models"

/// Writes an Ollama model: a manifest naming `layers` (digest number and size
/// in KB) and the blob files for them. A blob that already exists is left as
/// it is, which is how two models come to share one.
@discardableResult
private func makeOllamaModel(
    _ home: URL, host: String = "registry.ollama.ai", namespace: String = "library",
    model: String, tag: String, layers: [(Int, Int)], ageDays: Int = 30
) throws -> URL {
    let root = home.appending(path: ollamaRoot)
    for (n, size) in layers {
        let blob = root.appending(path: "blobs/sha256-\(digest(n))")
        if !fm.fileExists(atPath: blob.path) { try makeFile(blob, kbSize: size, ageDays: ageDays) }
    }
    let list = layers.dropFirst().map { "{\"mediaType\":\"x\",\"digest\":\"sha256:\(digest($0.0))\",\"size\":1}" }
    let json = "{\"schemaVersion\":2,\"config\":{\"mediaType\":\"c\",\"digest\":\"sha256:\(digest(layers[0].0))\",\"size\":1},"
        + "\"layers\":[\(list.joined(separator: ","))]}"
    let manifest = root.appending(path: "manifests/\(host)/\(namespace)/\(model)/\(tag)")
    try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: manifest)
    try setDate(manifest, daysAgo(ageDays))
    return manifest
}

private func makeHFFolder(_ home: URL, _ folder: String, files: [(String, Int)] = [("blobs/aaa", 200)]) throws -> URL {
    let dir = home.appending(path: ".cache/huggingface/hub/\(folder)")
    for (rel, size) in files { try makeFile(dir.appending(path: rel), kbSize: size) }
    if files.isEmpty { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    try backdate(dir)
    return dir
}

private func makeLMFolder(_ home: URL, _ rel: String, base: String = ".lmstudio/models",
                          kbSize: Int = 300) throws -> URL {
    let dir = home.appending(path: "\(base)/\(rel)")
    try makeFile(dir.appending(path: "model.gguf"), kbSize: kbSize)
    try backdate(dir)
    return dir
}

private func scan(_ home: URL, env: [String: String] = [:]) -> ModelScanResult {
    ModelScan.scan(roots: ModelScan.roots(home: home, environment: env))
}

private func roots(_ home: URL, env: [String: String] = [:]) -> [ModelRoot] {
    ModelScan.roots(home: home, environment: env)
}

private func names(_ r: ModelScanResult) -> [String] { r.items.map(\.name) }

/// A trash closure that only records what it was given.
private final class Recorder {
    var urls: [URL] = []
    var paths: [String] { urls.map(\.path) }
    func trash(_ url: URL) throws { urls.append(url) }
}

private struct TrashFailure: Error {}

// MARK: - Locations

@Suite("AI models: where they are looked for")
struct ModelRootTests {

    @Test("A home with no model folders gives an empty result, not an error")
    func missingLocationsAreEmpty() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        #expect(roots(home).isEmpty)
        let r = scan(home)
        #expect(r.items.isEmpty)
        #expect(r.lookedIn.isEmpty)
        #expect(!r.cancelled)
    }

    @Test("Each known location is found when it exists")
    func knownLocations() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        for p in [".ollama/models", ".cache/huggingface/hub", ".lmstudio/models", ".cache/lm-studio/models"] {
            try fm.createDirectory(at: home.appending(path: p), withIntermediateDirectories: true)
        }
        let found = roots(home)
        #expect(found.map(\.source) == [.ollama, .huggingFace, .lmStudio, .lmStudio])
        #expect(found.allSatisfy { ProjectScan.isInside($0.url, of: home) })
    }

    @Test("HF_HUB_CACHE and HF_HOME are honoured inside the home folder")
    func environmentInsideHome() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let hub = home.appending(path: "data/hf-hub")
        let hfHome = home.appending(path: "data/hf-home")
        try fm.createDirectory(at: hub, withIntermediateDirectories: true)
        try fm.createDirectory(at: hfHome.appending(path: "hub"), withIntermediateDirectories: true)

        let found = roots(home, env: ["HF_HUB_CACHE": hub.path, "HF_HOME": hfHome.path])
        #expect(Set(found.map(\.url.path)) == [hub.path, hfHome.appending(path: "hub").path])
        #expect(found.allSatisfy { $0.source == .huggingFace })
    }

    @Test("An environment folder outside the home folder is ignored")
    func environmentOutsideHome() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        try fm.createDirectory(at: elsewhere.appending(path: "hub"), withIntermediateDirectories: true)

        #expect(roots(home, env: ["HF_HUB_CACHE": elsewhere.path]).isEmpty)
        #expect(roots(home, env: ["HF_HOME": elsewhere.path]).isEmpty)
        // The home folder itself is not a model folder either.
        #expect(roots(home, env: ["HF_HUB_CACHE": home.path]).isEmpty)
        // A relative value means nothing.
        #expect(roots(home, env: ["HF_HUB_CACHE": "hub"]).isEmpty)
    }

    @Test("An environment folder that is a link out of the home folder is ignored")
    func environmentLinkOut() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        try fm.createSymbolicLink(at: home.appending(path: "hub"), withDestinationURL: elsewhere)

        #expect(roots(home, env: ["HF_HUB_CACHE": home.appending(path: "hub").path]).isEmpty)
    }

    @Test("A default location that is a link out of the home folder is not read")
    func defaultLinkOut() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let external = try makeHome(); defer { try? fm.removeItem(at: external) }
        try makeFile(external.appending(path: "blobs/sha256-\(digest(1))"))
        try fm.createDirectory(at: home.appending(path: ".ollama"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: ".ollama/models"), withDestinationURL: external)

        #expect(roots(home).isEmpty)
    }

    @Test("The same folder named twice is read once")
    func deduplicated() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let hub = home.appending(path: ".cache/huggingface/hub")
        try fm.createDirectory(at: hub, withIntermediateDirectories: true)

        #expect(roots(home, env: ["HF_HUB_CACHE": hub.path]).count == 1)
    }
}

// MARK: - Ollama

@Suite("AI models: Ollama")
struct OllamaModelTests {

    @Test("A manifest is one model, named the way Ollama names it")
    func naming() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "llama3", tag: "8b", layers: [(1, 64), (2, 128)])
        try makeOllamaModel(home, namespace: "someone", model: "mymodel", tag: "latest", layers: [(3, 64)])
        try makeOllamaModel(home, host: "hf.co", namespace: "org", model: "repo", tag: "Q4", layers: [(4, 64)])

        #expect(Set(names(scan(home))) == ["llama3:8b", "someone/mymodel:latest", "hf.co/org/repo:Q4"])
        #expect(scan(home).items.allSatisfy { $0.source == .ollama && $0.kind == .model })
    }

    @Test("The name helper covers each registry shape")
    func nameHelper() {
        #expect(ModelScan.ollamaName(host: "registry.ollama.ai", namespace: "library", model: "qwen", tag: "7b") == "qwen:7b")
        #expect(ModelScan.ollamaName(host: "registry.ollama.ai", namespace: "me", model: "m", tag: "x") == "me/m:x")
        #expect(ModelScan.ollamaName(host: "example.com", namespace: "a", model: "b", tag: "c") == "example.com/a/b:c")
    }

    @Test("Exclusive size counts only the blobs no other model uses")
    func exclusiveSize() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        // Blob 1 is shared. Blob 2 is only A's, blob 3 is only B's.
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 256), (2, 128)])
        try makeOllamaModel(home, model: "b", tag: "1", layers: [(1, 256), (3, 64)])

        let r = scan(home)
        let a = try #require(r.items.first { $0.name == "a:1" })
        let b = try #require(r.items.first { $0.name == "b:1" })
        let k = UInt64(kb)

        #expect(a.bytes == a.manifestBytes + 128 * k)
        #expect(a.totalBytes == a.manifestBytes + (256 + 128) * k)
        #expect(a.sharedBytes == 256 * k)
        #expect(b.bytes == b.manifestBytes + 64 * k)
        #expect(b.totalBytes == b.manifestBytes + (256 + 64) * k)
        #expect(ModelScan.sharedText(for: a) != nil)
        // Biggest first, by what removal frees.
        #expect(names(r) == ["a:1", "b:1"])
    }

    @Test("Two models sharing a blob: removing one frees only its own, removing both frees all")
    func freedBytesWithSharing() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 256), (2, 128)])
        try makeOllamaModel(home, model: "b", tag: "1", layers: [(1, 256), (3, 64)])

        let items = scan(home).items
        let a = try #require(items.first { $0.name == "a:1" })
        let b = try #require(items.first { $0.name == "b:1" })
        let k = UInt64(kb)

        #expect(ModelScan.freedBytes([a]) == a.manifestBytes + 128 * k)
        #expect(ModelScan.freedBytes([b]) == b.manifestBytes + 64 * k)
        // Both together also free the shared blob, once.
        #expect(ModelScan.freedBytes([a, b]) == a.manifestBytes + b.manifestBytes + (256 + 128 + 64) * k)
        #expect(ModelScan.freedBytes([a, b]) == ModelScan.freedBytes(items))
    }

    @Test("Moving one model sends its manifest and its own blobs, never a shared blob")
    func moveOneKeepsShared() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let ma = try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 256), (2, 128)])
        try makeOllamaModel(home, model: "b", tag: "1", layers: [(1, 256), (3, 64)])
        let items = scan(home).items
        let a = try #require(items.first { $0.name == "a:1" })

        let rec = Recorder()
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)

        let blobs = home.appending(path: "\(ollamaRoot)/blobs")
        #expect(Set(rec.paths) == [ma.path, blobs.appending(path: "sha256-\(digest(2))").path])
        #expect(r.moved == 1)
        #expect(r.movedPaths == [ma.path])
        #expect(r.bytes == a.bytes)
        #expect(r.refused.isEmpty && r.skippedRecent.isEmpty && r.failed.isEmpty)
    }

    @Test("Moving both models sends every blob once")
    func moveBothFreesAll() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 256), (2, 128)])
        try makeOllamaModel(home, model: "b", tag: "1", layers: [(1, 256), (3, 64)])
        let items = scan(home).items

        let rec = Recorder()
        let r = ModelScan.moveToTrash(items, roots: roots(home), trash: rec.trash)

        // Two manifests and three blobs, with the shared one sent once.
        #expect(rec.urls.count == 5)
        #expect(Set(rec.paths).count == 5)
        #expect(r.moved == 2)
        #expect(r.bytes == ModelScan.freedBytes(items))
    }

    @Test("A real removal leaves the other model whole and its size grows to match")
    func removeThenRescan() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 256), (2, 128)])
        let mb = try makeOllamaModel(home, model: "b", tag: "1", layers: [(1, 256), (3, 64)])
        let a = try #require(scan(home).items.first { $0.name == "a:1" })

        // Stands in for the Trash: the temp folder is the only thing it touches.
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: { try fm.removeItem(at: $0) })
        #expect(r.moved == 1)

        let blobs = home.appending(path: "\(ollamaRoot)/blobs")
        #expect(fm.fileExists(atPath: blobs.appending(path: "sha256-\(digest(1))").path))
        #expect(fm.fileExists(atPath: blobs.appending(path: "sha256-\(digest(3))").path))
        #expect(!fm.fileExists(atPath: blobs.appending(path: "sha256-\(digest(2))").path))
        #expect(fm.fileExists(atPath: mb.path))

        let b = try #require(scan(home).items.first)
        #expect(b.name == "b:1")
        #expect(b.sharedBytes == 0)
        #expect(b.bytes == b.manifestBytes + (256 + 64) * UInt64(kb))
    }

    @Test("A model left out of the move keeps the blobs it shares")
    func unselectedModelProtectsBlobs() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 128)])
        try makeOllamaModel(home, model: "a", tag: "2", layers: [(1, 128)])
        let items = scan(home).items
        let first = try #require(items.first { $0.name == "a:1" })

        let rec = Recorder()
        _ = ModelScan.moveToTrash([first], roots: roots(home), trash: rec.trash)
        // Only the manifest: the one blob is still named by a:2.
        #expect(rec.urls.count == 1)
        #expect(rec.paths[0].hasSuffix("manifests/registry.ollama.ai/library/a/1"))
    }

    @Test("A model pulled after the scan still protects its blobs at move time")
    func manifestsAreReadAgain() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 128), (2, 64)])
        let a = try #require(scan(home).items.first)
        // Someone pulls c, which reuses blob 2, after the list was built.
        try makeOllamaModel(home, model: "c", tag: "1", layers: [(2, 64)])

        let rec = Recorder()
        _ = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        let blobs = home.appending(path: "\(ollamaRoot)/blobs")
        #expect(rec.paths.contains(blobs.appending(path: "sha256-\(digest(1))").path))
        #expect(!rec.paths.contains(blobs.appending(path: "sha256-\(digest(2))").path))
    }

    @Test("A malformed manifest is skipped and counted, and nothing crashes")
    func malformedSkipped() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "good", tag: "1", layers: [(1, 64)])
        let dir = home.appending(path: "\(ollamaRoot)/manifests/registry.ollama.ai/library")
        let bad: [(String, String)] = [
            ("junk", "this is not json"),
            ("empty", ""),
            ("array", "[1,2,3]"),
            ("nolayers", "{\"schemaVersion\":2}"),
            ("baddigest", "{\"config\":{\"digest\":\"sha256:zzzz\"},\"layers\":[]}"),
            ("traversal", "{\"config\":{\"digest\":\"sha256:../../../../etc/passwd\"},\"layers\":[]}"),
            ("layerstring", "{\"config\":{\"digest\":\"sha256:\(digest(1))\"},\"layers\":\"x\"}"),
        ]
        for (name, body) in bad {
            let f = dir.appending(path: "\(name)/latest")
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: f)
            try setDate(f, daysAgo(30))
        }

        let r = scan(home)
        #expect(names(r) == ["good:1"])
        #expect(r.skippedMalformed == bad.count)
    }

    @Test("A malformed manifest is never moved, and still protects the blobs it names")
    func malformedProtectsBlobs() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 128)])
        // Names blob 1 and one bad digest, so it is not a manifest we trust.
        let f = home.appending(path: "\(ollamaRoot)/manifests/registry.ollama.ai/library/odd/latest")
        try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"config\":{\"digest\":\"sha256:\(digest(1))\"},\"layers\":[{\"digest\":\"nope\"}]}".utf8).write(to: f)
        try setDate(f, daysAgo(30))

        let a = try #require(scan(home).items.first)
        #expect(a.sharedBytes == 128 * UInt64(kb))
        let rec = Recorder()
        _ = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.count == 1)
    }

    @Test("Digest checking accepts only sha256 and 64 lowercase hex digits")
    func digestShape() {
        #expect(ModelScan.isDigest("sha256:" + digest(7)))
        #expect(!ModelScan.isDigest(digest(7)))
        #expect(!ModelScan.isDigest("sha256:" + String(digest(7).dropFirst())))
        #expect(!ModelScan.isDigest("sha256:" + digest(7).uppercased() + "G"))
        #expect(!ModelScan.isDigest("sha256:" + String(repeating: "A", count: 64)))
        #expect(!ModelScan.isDigest("sha256:../" + String(repeating: "a", count: 61)))
        #expect(!ModelScan.isDigest("md5:" + digest(7)))
    }

    @Test("A blob missing from disk is not counted and does not stop the move")
    func missingBlob() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let m = try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 128), (2, 64)])
        try fm.removeItem(at: home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(2))"))

        let a = try #require(scan(home).items.first)
        #expect(a.bytes == a.manifestBytes + 128 * UInt64(kb))
        let rec = Recorder()
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        #expect(r.moved == 1)
        #expect(rec.urls.count == 2)
        #expect(rec.paths.contains(m.path))
    }

    @Test("A symlinked manifest is ignored")
    func symlinkedManifest() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let real = try makeOllamaModel(home, model: "real", tag: "1", layers: [(1, 64)])
        let link = real.deletingLastPathComponent().deletingLastPathComponent().appending(path: "linked/1")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(names(scan(home)) == ["real:1"])
    }

    @Test("A symlinked model folder inside manifests is not entered")
    func symlinkedManifestFolder() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "real", tag: "1", layers: [(1, 64)])
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        let outside = elsewhere.appending(path: "m")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outside.appending(path: "latest"))
        let ns = home.appending(path: "\(ollamaRoot)/manifests/registry.ollama.ai/library")
        try fm.createSymbolicLink(at: ns.appending(path: "sneaky"), withDestinationURL: outside)

        let r = scan(home)
        #expect(names(r) == ["real:1"])
        #expect(r.skippedMalformed == 0)
    }

    @Test("A symlinked blob is not counted and not moved")
    func symlinkedBlob() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        let target = try makeFile(elsewhere.appending(path: "huge.bin"), kbSize: 900)
        let m = try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64), (2, 64)])
        let blob2 = home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(2))")
        try fm.removeItem(at: blob2)
        try fm.createSymbolicLink(at: blob2, withDestinationURL: target)

        let a = try #require(scan(home).items.first)
        #expect(a.bytes == a.manifestBytes + 64 * UInt64(kb))

        // A link that appears after the scan stops the model, and nothing moves.
        let b1 = home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(1))")
        try fm.removeItem(at: b1)
        try fm.createSymbolicLink(at: b1, withDestinationURL: target)
        let rec = Recorder()
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.moved == 0)
        #expect(r.refused == [m.path])
    }

    @Test("A manifest changed in the last minute is left out, and still protects shared blobs")
    func recentManifestSkipped() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "old", tag: "1", layers: [(1, 128)])
        try makeOllamaModel(home, model: "fresh", tag: "1", layers: [(1, 128)], ageDays: 0)

        let r = scan(home)
        #expect(names(r) == ["old:1"])
        #expect(r.skippedRecent == 1)
        // The fresh manifest still names the blob, so removing old frees none of it.
        #expect(r.items[0].sharedBytes == 128 * UInt64(kb))
    }

    @Test("A model whose blob changed in the last minute is left out")
    func recentBlobSkipped() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64)])
        try setDate(home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(1))"), Date())

        let r = scan(home)
        #expect(r.items.isEmpty)
        #expect(r.skippedRecent == 1)
    }

    @Test("A blob that becomes recent after the scan stops that model")
    func blobGoesRecentBeforeMove() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let m = try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64), (2, 64)])
        let a = try #require(scan(home).items.first)
        try setDate(home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(2))"), Date())

        let rec = Recorder()
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.skippedRecent == [m.path])
    }

    @Test("A partial download in progress is reported and pauses removal")
    func partialDownload() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64)])
        let a = try #require(scan(home).items.first)
        try makeFile(home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(9))-partial"), ageDays: 0)

        #expect(scan(home).ollamaDownloading)
        let rec = Recorder()
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.skippedRecent.count == 1)
    }

    @Test("An old partial file does not count as a download in progress")
    func stalePartial() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64)])
        try makeFile(home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(9))-partial"), ageDays: 3)

        #expect(!scan(home).ollamaDownloading)
    }

    @Test("A manifest that was replaced by a link after the scan is refused")
    func manifestSwappedForLink() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let m = try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64)])
        let a = try #require(scan(home).items.first)
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        let target = try makeFile(elsewhere.appending(path: "x"))
        try fm.removeItem(at: m)
        try fm.createSymbolicLink(at: m, withDestinationURL: target)

        let rec = Recorder()
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.refused == [m.path])
    }

    @Test("A manifest rewritten after the scan is not moved")
    func manifestRewritten() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let m = try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64)])
        let a = try #require(scan(home).items.first)
        try setDate(m, daysAgo(2))

        let rec = Recorder()
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.skippedRecent == [m.path])
    }

    @Test("If the manifest cannot be moved, its blobs stay")
    func manifestFailureKeepsBlobs() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let m = try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64), (2, 64)])
        let a = try #require(scan(home).items.first)

        var tried: [String] = []
        let r = ModelScan.moveToTrash([a], roots: roots(home), trash: { url in
            tried.append(url.path)
            throw TrashFailure()
        })
        #expect(tried == [m.path])
        #expect(r.moved == 0)
        #expect(r.bytes == 0)
        #expect(r.failed == [m.path])
    }
}

// MARK: - Hugging Face

@Suite("AI models: Hugging Face")
struct HuggingFaceModelTests {

    @Test("models--org--name becomes org/name")
    func repoNaming() {
        #expect(ModelScan.huggingFaceName("models--meta-llama--Llama-3.1-8B")?.name == "meta-llama/Llama-3.1-8B")
        #expect(ModelScan.huggingFaceName("models--gpt2")?.name == "gpt2")
        #expect(ModelScan.huggingFaceName("models--org--name")?.kind == .model)
        #expect(ModelScan.huggingFaceName("datasets--org--data")?.kind == .dataset)
        #expect(ModelScan.huggingFaceName("spaces--org--demo")?.kind == .space)
        #expect(ModelScan.huggingFaceName("models--") == nil)
        #expect(ModelScan.huggingFaceName("models----x") == nil)
        #expect(ModelScan.huggingFaceName("version.txt") == nil)
        #expect(ModelScan.huggingFaceName(".locks") == nil)
    }

    @Test("Models, datasets and spaces are listed, with their kind")
    func listsKinds() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeHFFolder(home, "models--org--big", files: [("blobs/a", 400)])
        try makeHFFolder(home, "datasets--org--corpus", files: [("blobs/a", 300)])
        try makeHFFolder(home, "spaces--org--demo", files: [("blobs/a", 200)])

        let r = scan(home)
        #expect(names(r) == ["org/big", "org/corpus", "org/demo"])
        #expect(r.items.map(\.kind) == [.model, .dataset, .space])
        #expect(r.items.allSatisfy { $0.source == .huggingFace })
    }

    @Test("Other entries in the cache folder are ignored")
    func ignoresOthers() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let hub = home.appending(path: ".cache/huggingface/hub")
        try makeHFFolder(home, "models--org--a")
        try makeFile(hub.appending(path: ".locks/models--org--a/x.lock"))
        try makeFile(hub.appending(path: "version.txt"))
        try makeFile(hub.appending(path: "random-folder/big.bin"))

        #expect(names(scan(home)) == ["org/a"])
    }

    @Test("Snapshot links are not counted twice")
    func snapshotLinks() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a", files: [("blobs/abc", 256)])
        let snap = dir.appending(path: "snapshots/rev1")
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: snap.appending(path: "model.safetensors"),
                                  withDestinationURL: dir.appending(path: "blobs/abc"))
        try backdate(dir)

        let a = try #require(scan(home).items.first)
        #expect(a.bytes == 256 * UInt64(kb))
        #expect(a.totalBytes == a.bytes)
    }

    @Test("A symlinked model folder is ignored")
    func symlinkedFolderIgnored() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        try makeFile(elsewhere.appending(path: "blobs/huge"), kbSize: 900)
        try backdate(elsewhere)
        try makeHFFolder(home, "models--org--real")
        let hub = home.appending(path: ".cache/huggingface/hub")
        try fm.createSymbolicLink(at: hub.appending(path: "models--org--linked"), withDestinationURL: elsewhere)

        #expect(names(scan(home)) == ["org/real"])
    }

    @Test("A folder with nothing on disk is not listed")
    func emptyFolder() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeHFFolder(home, "models--org--empty", files: [])
        #expect(scan(home).items.isEmpty)
    }

    @Test("A model with a file changed in the last minute is left out and counted")
    func recentSkipped() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--downloading")
        try makeFile(dir.appending(path: "blobs/new.incomplete"), ageDays: 0)
        try makeHFFolder(home, "models--org--done")

        let r = scan(home)
        #expect(names(r) == ["org/done"])
        #expect(r.skippedRecent == 1)
    }

    @Test("A date in the future counts as recent")
    func futureDate() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        try setDate(dir.appending(path: "blobs/aaa"), Date().addingTimeInterval(3600))

        #expect(scan(home).items.isEmpty)
    }

    @Test("A cache named by HF_HUB_CACHE inside the home folder is read")
    func environmentCache() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let hub = home.appending(path: "data/hub")
        try makeFile(hub.appending(path: "models--org--moved/blobs/a"), kbSize: 200)
        try backdate(hub)

        #expect(names(scan(home, env: ["HF_HUB_CACHE": hub.path])) == ["org/moved"])
        #expect(scan(home).items.isEmpty)
    }

    @Test("A folder moves as one item through the injected closure, with its size")
    func moveFolder() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a", files: [("blobs/a", 300), ("blobs/b", 100)])
        let item = try #require(scan(home).items.first)

        let rec = Recorder()
        let r = ModelScan.moveToTrash([item], roots: roots(home), trash: rec.trash)
        #expect(rec.paths == [dir.path])
        #expect(r.moved == 1)
        #expect(r.bytes == 400 * UInt64(kb))
        #expect(r.movedPaths == [dir.path])
    }

    @Test("A failed Trash call is reported and not counted")
    func moveFailure() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let item = try #require(scan(home).items.first)

        let r = ModelScan.moveToTrash([item], roots: roots(home), trash: { _ in throw TrashFailure() })
        #expect(r.moved == 0)
        #expect(r.bytes == 0)
        #expect(r.failed == [dir.path])
    }
}

// MARK: - LM Studio

@Suite("AI models: LM Studio")
struct LMStudioModelTests {

    @Test("publisher/model folders are listed, in both locations")
    func listsFolders() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeLMFolder(home, "lmstudio-community/Qwen-7B-GGUF", kbSize: 400)
        try makeLMFolder(home, "TheBloke/Mistral-GGUF", kbSize: 300)
        try makeLMFolder(home, "old/Thing", base: ".cache/lm-studio/models", kbSize: 200)

        let r = scan(home)
        #expect(names(r) == ["lmstudio-community/Qwen-7B-GGUF", "TheBloke/Mistral-GGUF", "old/Thing"])
        #expect(r.items.allSatisfy { $0.source == .lmStudio && $0.kind == .model })
        #expect(r.items.map(\.bytes) == [400, 300, 200].map { UInt64($0 * kb) })
    }

    @Test("Files sitting directly in a publisher folder are not models")
    func looseFiles() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeFile(home.appending(path: ".lmstudio/models/pub/loose.gguf"))
        try backdate(home.appending(path: ".lmstudio/models"))

        #expect(scan(home).items.isEmpty)
    }

    @Test("A symlinked model folder, and a symlinked publisher, are ignored")
    func symlinksIgnored() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        try makeFile(elsewhere.appending(path: "model.gguf"), kbSize: 900)
        try backdate(elsewhere)
        try makeLMFolder(home, "pub/real")
        let root = home.appending(path: ".lmstudio/models")
        try fm.createSymbolicLink(at: root.appending(path: "pub/linked"), withDestinationURL: elsewhere)
        try fm.createSymbolicLink(at: root.appending(path: "linkedpub"), withDestinationURL: elsewhere)

        #expect(names(scan(home)) == ["pub/real"])
    }

    @Test("Hidden folders are skipped")
    func hiddenSkipped() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeLMFolder(home, ".hidden/model")
        try makeLMFolder(home, "pub/.cache")
        try makeLMFolder(home, "pub/shown")

        #expect(names(scan(home)) == ["pub/shown"])
    }

    @Test("A LM Studio folder moves through the injected closure")
    func moveFolder() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeLMFolder(home, "pub/m", kbSize: 500)
        let item = try #require(scan(home).items.first)

        let rec = Recorder()
        let r = ModelScan.moveToTrash([item], roots: roots(home), trash: rec.trash)
        #expect(rec.paths == [dir.path])
        #expect(r.bytes == 500 * UInt64(kb))
    }
}

// MARK: - The last-moment check

@Suite("AI models: verify before moving")
struct ModelVerifyTests {

    private func item(_ url: URL, source: ModelSource, kind: ModelKind = .model,
                      root: URL, modified: Date? = nil) -> ModelItem {
        ModelItem(source: source, kind: kind, name: "x", url: url, root: root,
                  bytes: 1, totalBytes: 1, sizeCapped: false, manifestBytes: 0, blobs: [],
                  lastAccessed: nil, lastModified: modified)
    }

    @Test("A listed folder passes")
    func okPasses() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeHFFolder(home, "models--org--a")
        let it = try #require(scan(home).items.first)
        #expect(ModelScan.verify(it, roots: roots(home)) == .ok)
    }

    @Test("A path outside every model folder is refused")
    func outsideRoot() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeHFFolder(home, "models--org--a")
        let other = home.appending(path: "Documents/models--org--b")
        try makeFile(other.appending(path: "x"))
        try backdate(other)

        let it = item(other, source: .huggingFace, root: home.appending(path: ".cache/huggingface/hub"))
        guard case .refused = ModelScan.verify(it, roots: roots(home)) else {
            Issue.record("expected a refusal"); return
        }
    }

    @Test("A sibling folder with a similar name is not inside the model folder")
    func prefixLookalike() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeHFFolder(home, "models--org--a")
        let lookalike = home.appending(path: ".cache/huggingface/hub-evil/models--org--a")
        try makeFile(lookalike.appending(path: "x"))
        try backdate(lookalike)

        let it = item(lookalike, source: .huggingFace, root: home.appending(path: ".cache/huggingface/hub"))
        guard case .refused = ModelScan.verify(it, roots: roots(home)) else {
            Issue.record("expected a refusal"); return
        }
    }

    @Test("The model folder itself and a folder deeper than a model are refused")
    func wrongDepth() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let hub = home.appending(path: ".cache/huggingface/hub")
        let rs = roots(home)

        for url in [hub, dir.appending(path: "blobs")] {
            let it = item(url, source: .huggingFace, root: hub)
            guard case .refused = ModelScan.verify(it, roots: rs) else {
                Issue.record("expected a refusal for \(url.path)"); return
            }
        }
    }

    @Test("A folder replaced by a symlink after the scan is refused")
    func swappedForSymlink() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let it = try #require(scan(home).items.first)
        let elsewhere = try makeHome(); defer { try? fm.removeItem(at: elsewhere) }
        try makeFile(elsewhere.appending(path: "keep.me"))
        try fm.removeItem(at: dir)
        try fm.createSymbolicLink(at: dir, withDestinationURL: elsewhere)

        #expect(ModelScan.verify(it, roots: roots(home)) == .refused("a symlink"))
        let rec = Recorder()
        let r = ModelScan.moveToTrash([it], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.refused == [dir.path])
    }

    @Test("A parent folder that became a symlink is refused")
    func parentSymlink() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let it = try #require(scan(home).items.first)
        let hub = home.appending(path: ".cache/huggingface/hub")
        let moved = home.appending(path: ".cache/huggingface/hub-real")
        try fm.moveItem(at: hub, to: moved)
        try fm.createSymbolicLink(at: hub, withDestinationURL: moved)

        #expect(ModelScan.verify(it, roots: roots(home)) == .refused("a symlink is involved"))
        let rec = Recorder()
        let r = ModelScan.moveToTrash([it], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.refused == [dir.path])
    }

    @Test("A folder that became a file is refused")
    func kindChanged() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let it = try #require(scan(home).items.first)
        try fm.removeItem(at: dir)
        try makeFile(dir)

        #expect(ModelScan.verify(it, roots: roots(home)) == .refused("not a folder"))
    }

    @Test("A path that is gone is refused")
    func gone() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let it = try #require(scan(home).items.first)
        try fm.removeItem(at: dir)

        guard case .refused = ModelScan.verify(it, roots: roots(home)) else {
            Issue.record("expected a refusal"); return
        }
    }

    @Test("A file written inside the folder in the last minute is too recent")
    func recentlyModified() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let it = try #require(scan(home).items.first)
        try makeFile(dir.appending(path: "blobs/fresh.incomplete"), ageDays: 0)

        #expect(ModelScan.verify(it, roots: roots(home)) == .tooRecent)
        let rec = Recorder()
        let r = ModelScan.moveToTrash([it], roots: roots(home), trash: rec.trash)
        #expect(rec.urls.isEmpty)
        #expect(r.skippedRecent == [dir.path])
    }

    @Test("A folder changed since the scan, even by an old date, is not the one listed")
    func changedSinceScan() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeHFFolder(home, "models--org--a")
        let it = try #require(scan(home).items.first)
        try makeFile(dir.appending(path: "blobs/other"), ageDays: 5)

        #expect(ModelScan.verify(it, roots: roots(home)) == .tooRecent)
    }

    @Test("A hidden folder is refused")
    func hidden() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeLMFolder(home, "pub/.secret")
        let root = home.appending(path: ".lmstudio/models")
        let it = item(dir, source: .lmStudio, root: root)
        #expect(ModelScan.verify(it, roots: roots(home)) == .refused("hidden"))
    }

    @Test("An item from one tool is not accepted under another tool's folder")
    func wrongSource() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        let dir = try makeLMFolder(home, "pub/m")
        let it = item(dir, source: .huggingFace, root: home.appending(path: ".lmstudio/models"))
        guard case .refused = ModelScan.verify(it, roots: roots(home)) else {
            Issue.record("expected a refusal"); return
        }
    }

    @Test("A path with a parent reference is refused")
    func dotDot() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeHFFolder(home, "models--org--a")
        let hub = home.appending(path: ".cache/huggingface/hub")
        let sneaky = URL(fileURLWithPath: hub.path + "/models--org--a/../models--org--a")
        let it = item(sneaky, source: .huggingFace, root: hub)
        // Whatever the wording, it must not be accepted.
        #expect(ModelScan.verify(it, roots: roots(home)) != .ok)
    }

    @Test("An Ollama manifest outside the manifests folder is refused")
    func ollamaWrongPlace() throws {
        let home = try makeHome(); defer { try? fm.removeItem(at: home) }
        try makeOllamaModel(home, model: "a", tag: "1", layers: [(1, 64)])
        let blob = home.appending(path: "\(ollamaRoot)/blobs/sha256-\(digest(1))")
        let it = item(blob, source: .ollama, root: home.appending(path: ollamaRoot))

        guard case .refused = ModelScan.verify(it, roots: roots(home)) else {
            Issue.record("expected a refusal"); return
        }
    }
}

// MARK: - Wording and order

@Suite("AI models: ordering and wording")
struct ModelWordingTests {

    private func make(_ name: String, bytes: UInt64, accessed: Date? = nil, modified: Date? = nil) -> ModelItem {
        ModelItem(source: .lmStudio, kind: .model, name: name,
                  url: URL(fileURLWithPath: "/tmp/\(name)"), root: URL(fileURLWithPath: "/tmp"),
                  bytes: bytes, totalBytes: bytes, sizeCapped: false, manifestBytes: 0, blobs: [],
                  lastAccessed: accessed, lastModified: modified)
    }

    @Test("Sorted by size, largest first, ties by name")
    func sortBySize() {
        let list = [make("b", bytes: 10), make("c", bytes: 30), make("a", bytes: 10)]
        #expect(ModelScan.sorted(list).map(\.name) == ["c", "a", "b"])
    }

    @Test("Last used says opened when there is an access date and modified when there is not")
    func ageWording() {
        let now = Date()
        let old = now.addingTimeInterval(-90 * 86_400)
        #expect(ModelScan.ageText(for: make("a", bytes: 1, accessed: old, modified: old), now: now) == "Not opened for 3 months")
        #expect(ModelScan.ageText(for: make("a", bytes: 1, accessed: now, modified: old), now: now) == "Opened today")
        #expect(ModelScan.ageText(for: make("a", bytes: 1, modified: old), now: now) == "Modified 3 months ago")
        #expect(ModelScan.ageText(for: make("a", bytes: 1), now: now) == "Date unknown")
    }

    @Test("A recent change wins over an old access date")
    func newestWins() {
        let now = Date()
        let it = make("a", bytes: 1, accessed: now.addingTimeInterval(-400 * 86_400), modified: now)
        #expect(ModelScan.ageText(for: it, now: now) == "Opened today")
    }

    @Test("Total freed for folder models is the sum of their sizes")
    func freedForFolders() {
        let list = [make("a", bytes: 100), make("b", bytes: 50)]
        #expect(ModelScan.freedBytes(list) == 150)
        #expect(ModelScan.freedBytes([]) == 0)
    }

    @Test("Strings in this feature use no em or en dashes")
    func noDashes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/BoostKit")
        for file in ["ModelScan.swift", "ModelEngine.swift", "ModelView.swift"] {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            #expect(!text.contains("\u{2014}"), "\(file) has an em dash")
            #expect(!text.contains("\u{2013}"), "\(file) has an en dash")
        }
    }
}
