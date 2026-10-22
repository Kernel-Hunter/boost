import Foundation

// MARK: - Where the AI Models tab looks

/// The tools whose downloaded models the tab lists.
public enum ModelSource: String, Sendable, CaseIterable {
    case ollama, huggingFace, lmStudio

    public var title: String {
        switch self {
        case .ollama:      return "Ollama"
        case .huggingFace: return "Hugging Face"
        case .lmStudio:    return "LM Studio"
        }
    }
}

/// What a Hugging Face cache folder holds. Ollama and LM Studio entries are
/// always models.
public enum ModelKind: String, Sendable {
    case model, dataset, space

    public var title: String {
        switch self {
        case .model:   return "Model"
        case .dataset: return "Dataset"
        case .space:   return "Space"
        }
    }
}

/// One folder that holds models, resolved. Always inside the home folder.
public struct ModelRoot: Sendable, Equatable {
    public let source: ModelSource
    /// Symlink-resolved, so every path found below is spelled the way
    /// `verify` will later spell it.
    public let url: URL
}

/// A place models live, relative to the home folder. Adding another tool that
/// keeps one folder per model is one line in `ModelScan.locations`.
struct ModelLocation: Sendable {
    let source: ModelSource
    let path: String
}

/// An environment variable that moves a cache. It is honoured only when it
/// points somewhere inside the home folder.
struct ModelEnvironmentLocation: Sendable {
    let variable: String
    /// Added to the variable's value, for variables that name a parent folder.
    let subpath: String?
    let source: ModelSource
}

// MARK: - Results

/// One blob of an Ollama model, with every manifest that names it.
public struct ModelBlob: Sendable, Equatable {
    /// The 64 hex digits after `sha256:`.
    public let digest: String
    public let bytes: UInt64
    /// Paths of every manifest on disk that lists this blob, including ones
    /// the list leaves out. Blobs are shared, and a blob only leaves the disk
    /// when all of its owners do.
    public let owners: [String]
}

/// One row in the AI Models list: an Ollama model (one manifest), or one
/// Hugging Face or LM Studio folder.
public struct ModelItem: Identifiable, Sendable, Equatable {
    /// The manifest path for Ollama, the model folder otherwise. Unique and
    /// stable across rescans.
    public var id: String { url.path }
    public let source: ModelSource
    public let kind: ModelKind
    /// "llama3:8b", "org/name" or "publisher/model".
    public let name: String
    /// The manifest file for Ollama, the model folder otherwise.
    public let url: URL
    /// The folder the item was found in.
    public let root: URL
    /// Allocated size of what moving this item frees: for Ollama the manifest
    /// and the blobs no other model uses, for a folder everything in it.
    public let bytes: UInt64
    /// Everything the model needs, shared or not.
    public let totalBytes: UInt64
    /// True when sizing stopped at the entry cap, so the sizes are a floor.
    public let sizeCapped: Bool
    /// Ollama only: the manifest file's own size.
    public let manifestBytes: UInt64
    /// Ollama only: the blobs the manifest names that exist on disk.
    public let blobs: [ModelBlob]
    public let lastAccessed: Date?
    /// For Ollama the manifest's date, for a folder the newest change inside it.
    public let lastModified: Date?

    public var folder: URL { url.deletingLastPathComponent() }
    public var sharedBytes: UInt64 { totalBytes > bytes ? totalBytes - bytes : 0 }

    /// The newest sign the model was used. A pull or an update counts as use,
    /// so a recent change wins over an old access date.
    public var lastUsed: Date? { [lastAccessed, lastModified].compactMap { $0 }.max() }
}

public struct ModelScanResult: Sendable {
    /// Biggest first.
    public var items: [ModelItem] = []
    /// Changed in the last minute, so probably still downloading.
    public var skippedRecent = 0
    /// Ollama manifests that could not be read. They are not listed and not
    /// touched.
    public var skippedMalformed = 0
    /// True when a partial Ollama download was written to in the last minute.
    public var ollamaDownloading = false
    /// The folders that exist and were read.
    public var lookedIn: [URL] = []
    public var cancelled = false
}

public struct ModelTrashResult: Sendable {
    /// Models moved. A model counts once, however many files it took.
    public var moved = 0
    public var bytes: UInt64 = 0
    /// Item ids that went to the Trash, so the list can drop exactly those.
    public var movedPaths: [String] = []
    /// Changed since the scan, or modified in the last minute.
    public var skippedRecent: [String] = []
    /// Failed the last-moment safety check.
    public var refused: [String] = []
    /// The Trash call itself threw: in use, or not permitted. For Ollama this
    /// can also be one shared file after its model was already moved.
    public var failed: [String] = []
}

public enum ModelVerdict: Sendable, Equatable {
    case ok
    case tooRecent
    case refused(String)
}

// MARK: - Scan

public enum ModelScan {

    /// A model that changed less than this long ago is left alone: it may
    /// still be downloading.
    public static let recentWindow: TimeInterval = 60

    /// Entries read when sizing one model folder.
    public static let defaultMaxEntries = 200_000

    private static var fm: FileManager { .default }

    // MARK: - Roots

    /// The data table. Paths are relative to the home folder.
    static let locations: [ModelLocation] = [
        ModelLocation(source: .ollama,      path: ".ollama/models"),
        ModelLocation(source: .huggingFace, path: ".cache/huggingface/hub"),
        ModelLocation(source: .lmStudio,    path: ".lmstudio/models"),
        ModelLocation(source: .lmStudio,    path: ".cache/lm-studio/models"),
    ]

    static let environmentLocations: [ModelEnvironmentLocation] = [
        ModelEnvironmentLocation(variable: "HF_HUB_CACHE", subpath: nil,   source: .huggingFace),
        ModelEnvironmentLocation(variable: "HF_HOME",      subpath: "hub", source: .huggingFace),
    ]

    /// The model folders that exist, resolved and de-duplicated.
    ///
    /// Everything has to resolve to somewhere strictly inside the home folder.
    /// A cache moved to an external disk through a link is not read, and an
    /// environment variable pointing outside the home folder is ignored.
    public static func roots(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ModelRoot] {
        let base = home ?? fm.homeDirectoryForCurrentUser
        let canonicalHome = ProjectScan.canonical(base)

        var candidates: [(ModelSource, URL)] = locations.map { ($0.source, base.appending(path: $0.path)) }
        for e in environmentLocations {
            guard let raw = environment[e.variable], raw.hasPrefix("/") else { continue }
            var url = URL(fileURLWithPath: raw)
            if let sub = e.subpath { url = url.appending(path: sub) }
            candidates.append((e.source, url))
        }

        var seen = Set<String>()
        var out: [ModelRoot] = []
        for (source, url) in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let resolved = ProjectScan.canonical(url)
            guard ProjectScan.isInside(resolved, of: canonicalHome) else { continue }
            guard seen.insert(resolved.path).inserted else { continue }
            out.append(ModelRoot(source: source, url: resolved))
        }
        return out
    }

    // MARK: - Scanning

    /// Lists the models under `roots`. Read only. Slow on a big cache: call it
    /// off the main actor. Cancellation is cooperative through `isCancelled`.
    ///
    /// Hidden entries are skipped and every symlink is ignored rather than
    /// followed, so a link into a big tree elsewhere is neither counted nor
    /// entered. A model that changed in the last minute is left out and counted.
    public static func scan(
        roots: [ModelRoot],
        now: Date = Date(),
        maxEntries: Int = defaultMaxEntries,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ModelScanResult {
        var result = ModelScanResult()
        for root in roots {
            if isCancelled() { result.cancelled = true; return result }
            result.lookedIn.append(root.url)
            switch root.source {
            case .ollama:
                scanOllama(root, now: now, isCancelled: isCancelled, into: &result)
            case .huggingFace:
                scanHuggingFace(root, now: now, maxEntries: maxEntries, isCancelled: isCancelled, into: &result)
            case .lmStudio:
                scanLMStudio(root, now: now, maxEntries: maxEntries, isCancelled: isCancelled, into: &result)
            }
            if result.cancelled { return result }
        }
        result.items = sorted(result.items)
        return result
    }

    // MARK: Hugging Face

    static let huggingFacePrefixes: [(prefix: String, kind: ModelKind)] = [
        ("models--", .model), ("datasets--", .dataset), ("spaces--", .space),
    ]

    /// "models--org--name" becomes "org/name". Repos without an organisation
    /// ("models--gpt2") keep their bare name.
    static func huggingFaceName(_ folder: String) -> (name: String, kind: ModelKind)? {
        for (prefix, kind) in huggingFacePrefixes where folder.hasPrefix(prefix) {
            let rest = String(folder.dropFirst(prefix.count))
            guard !rest.isEmpty else { return nil }
            if let r = rest.range(of: "--") {
                let org = String(rest[..<r.lowerBound]), repo = String(rest[r.upperBound...])
                guard !org.isEmpty, !repo.isEmpty else { return nil }
                return ("\(org)/\(repo)", kind)
            }
            return (rest, kind)
        }
        return nil
    }

    private static func scanHuggingFace(
        _ root: ModelRoot, now: Date, maxEntries: Int,
        isCancelled: @Sendable () -> Bool, into result: inout ModelScanResult
    ) {
        for entry in directories(in: root.url) {
            if isCancelled() { result.cancelled = true; return }
            guard let (name, kind) = huggingFaceName(entry.lastPathComponent) else { continue }
            appendFolder(entry, name: name, kind: kind, root: root, now: now,
                         maxEntries: maxEntries, isCancelled: isCancelled, into: &result)
        }
    }

    // MARK: LM Studio

    private static func scanLMStudio(
        _ root: ModelRoot, now: Date, maxEntries: Int,
        isCancelled: @Sendable () -> Bool, into result: inout ModelScanResult
    ) {
        for publisher in directories(in: root.url) {
            for model in directories(in: publisher) {
                if isCancelled() { result.cancelled = true; return }
                let name = publisher.lastPathComponent + "/" + model.lastPathComponent
                appendFolder(model, name: name, kind: .model, root: root, now: now,
                             maxEntries: maxEntries, isCancelled: isCancelled, into: &result)
            }
        }
    }

    private static func appendFolder(
        _ folder: URL, name: String, kind: ModelKind, root: ModelRoot, now: Date,
        maxEntries: Int, isCancelled: @Sendable () -> Bool, into result: inout ModelScanResult
    ) {
        let m = measure(folder, entryCap: maxEntries, isCancelled: isCancelled)
        if m.cancelled { result.cancelled = true; return }
        // Nothing on disk, so nothing to free.
        guard m.bytes > 0 else { return }
        // A date in the future counts as recent: a wrong clock is a reason to
        // leave it alone.
        if let newest = m.newestModified, now.timeIntervalSince(newest) < recentWindow {
            result.skippedRecent += 1
            return
        }
        result.items.append(ModelItem(
            source: root.source, kind: kind, name: name, url: folder, root: root.url,
            bytes: m.bytes, totalBytes: m.bytes, sizeCapped: m.capped,
            manifestBytes: 0, blobs: [],
            lastAccessed: m.newestAccessed, lastModified: m.newestModified))
    }

    // MARK: Ollama

    /// One manifest file, read.
    struct OllamaManifest {
        let url: URL
        let name: String
        /// The blobs it names, without repeats.
        let digests: [String]
        /// False when the file is not a manifest this tab understands. It is
        /// then never listed or moved, but the blobs it names still count as
        /// used, so a shared blob is not freed by mistake.
        let valid: Bool
        let bytes: UInt64
        let modified: Date?
        let accessed: Date?
    }

    private static let manifestSizeCap = 1_048_576

    /// A blob digest is `sha256:` and 64 lowercase hex digits. Anything else
    /// is refused, so a manifest cannot point a move at another path.
    static func isDigest(_ s: String) -> Bool {
        guard s.hasPrefix("sha256:") else { return false }
        let hex = s.dropFirst("sha256:".count)
        return hex.count == 64 && hex.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// The digests a manifest names, from its `config` and its `layers`.
    /// `valid` is false for anything that is not a manifest with at least one
    /// good digest and no bad one.
    static func parseManifest(_ data: Data) -> (digests: [String], valid: Bool) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], false) }
        var found: [String] = []
        var valid = true
        func take(_ value: Any?) {
            guard let s = value as? String, isDigest(s) else { valid = false; return }
            let hex = String(s.dropFirst("sha256:".count))
            if !found.contains(hex) { found.append(hex) }
        }
        if let config = obj["config"] {
            guard let c = config as? [String: Any] else { return (found, false) }
            take(c["digest"])
        }
        if let layers = obj["layers"] {
            guard let list = layers as? [Any] else { return (found, false) }
            for layer in list {
                guard let l = layer as? [String: Any] else { valid = false; continue }
                take(l["digest"])
            }
        }
        return (found, valid && !found.isEmpty)
    }

    /// "llama3:8b" for the main registry's own models, "user/model:tag" for a
    /// user's, "host/user/model:tag" for another registry.
    static func ollamaName(host: String, namespace: String, model: String, tag: String) -> String {
        let base: String
        if host == "registry.ollama.ai" {
            base = namespace == "library" ? model : "\(namespace)/\(model)"
        } else {
            base = "\(host)/\(namespace)/\(model)"
        }
        return "\(base):\(tag)"
    }

    /// Every manifest under `<root>/manifests/<host>/<namespace>/<model>/<tag>`.
    /// Hidden entries and symlinks are ignored.
    static func readOllamaManifests(root: URL) -> [OllamaManifest] {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]
        var out: [OllamaManifest] = []
        for host in directories(in: root.appending(path: "manifests")) {
            for ns in directories(in: host) {
                for model in directories(in: ns) {
                    for file in regularFiles(in: model) {
                        let v = try? file.resourceValues(forKeys: keys)
                        let bytes = UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
                        var parsed: (digests: [String], valid: Bool) = ([], false)
                        if bytes <= UInt64(manifestSizeCap), let data = try? Data(contentsOf: file),
                           data.count <= manifestSizeCap {
                            parsed = parseManifest(data)
                        }
                        out.append(OllamaManifest(
                            url: file,
                            name: ollamaName(host: host.lastPathComponent, namespace: ns.lastPathComponent,
                                             model: model.lastPathComponent, tag: file.lastPathComponent),
                            digests: parsed.digests, valid: parsed.valid, bytes: bytes,
                            modified: v?.contentModificationDate, accessed: v?.contentAccessDate))
                    }
                }
            }
        }
        return out
    }

    /// For every blob, the manifests that name it.
    static func owners(of manifests: [OllamaManifest]) -> [String: [String]] {
        var table: [String: [String]] = [:]
        for m in manifests {
            for d in m.digests { table[d, default: []].append(m.url.path) }
        }
        return table.mapValues { $0.sorted() }
    }

    struct BlobInfo {
        let bytes: UInt64
        let modified: Date?
        let accessed: Date?
    }

    static func blobURL(root: URL, digest: String) -> URL {
        root.appending(path: "blobs").appending(path: "sha256-" + digest)
    }

    /// A blob that is a plain file. A missing blob, a symlink or anything else
    /// is `nil` and is neither counted nor touched.
    private static func blobInfo(root: URL, digest: String) -> BlobInfo? {
        let url = blobURL(root: root, digest: digest)
        guard let v = try? url.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]), v.isSymbolicLink != true, v.isRegularFile == true else { return nil }
        return BlobInfo(bytes: UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0),
                        modified: v.contentModificationDate, accessed: v.contentAccessDate)
    }

    /// Ollama writes a download to `sha256-<hex>-partial` until it is whole. A
    /// partial file written to in the last minute means a pull is running.
    static func downloadActive(root: URL, now: Date) -> Bool {
        let dir = root.appending(path: "blobs")
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        for name in names where name.contains("-partial") {
            let v = try? dir.appending(path: name).resourceValues(forKeys: [.contentModificationDateKey])
            if let m = v?.contentModificationDate, now.timeIntervalSince(m) < recentWindow { return true }
        }
        return false
    }

    private static func scanOllama(
        _ root: ModelRoot, now: Date,
        isCancelled: @Sendable () -> Bool, into result: inout ModelScanResult
    ) {
        let manifests = readOllamaManifests(root: root.url)
        let table = owners(of: manifests)
        if downloadActive(root: root.url, now: now) { result.ollamaDownloading = true }

        var blobCache: [String: BlobInfo?] = [:]
        func info(_ digest: String) -> BlobInfo? {
            if let hit = blobCache[digest] { return hit }
            let i = blobInfo(root: root.url, digest: digest)
            blobCache[digest] = .some(i)
            return i
        }

        for m in manifests {
            if isCancelled() { result.cancelled = true; return }
            guard m.valid else { result.skippedMalformed += 1; continue }

            var blobs: [ModelBlob] = []
            var accessed = m.accessed
            var recent = false
            // A date in the future counts as recent, as everywhere else.
            if let d = m.modified, now.timeIntervalSince(d) < recentWindow { recent = true }
            for digest in m.digests {
                guard let i = info(digest) else { continue }
                blobs.append(ModelBlob(digest: digest, bytes: i.bytes, owners: table[digest] ?? [m.url.path]))
                if let a = i.accessed { accessed = max(accessed ?? a, a) }
                if let d = i.modified, now.timeIntervalSince(d) < recentWindow { recent = true }
            }
            if recent { result.skippedRecent += 1; continue }

            let own = [m.url.path]
            let exclusive = blobs.filter { $0.owners == own }.reduce(UInt64(0)) { $0 + $1.bytes }
            let total = blobs.reduce(UInt64(0)) { $0 + $1.bytes }
            result.items.append(ModelItem(
                source: .ollama, kind: .model, name: m.name, url: m.url, root: root.url,
                bytes: m.bytes + exclusive, totalBytes: m.bytes + total, sizeCapped: false,
                manifestBytes: m.bytes, blobs: blobs,
                lastAccessed: accessed, lastModified: m.modified))
        }
    }

    // MARK: - Reading folders

    private static let entryKeys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]

    /// The visible, non-symlink subfolders of `dir`, by name.
    private static func directories(in dir: URL) -> [URL] {
        children(of: dir) { $0.isDirectory == true }
    }

    private static func regularFiles(in dir: URL) -> [URL] {
        children(of: dir) { $0.isRegularFile == true }
    }

    private static func children(of dir: URL, where keep: (URLResourceValues) -> Bool) -> [URL] {
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(entryKeys), options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { u in
                guard let v = try? u.resourceValues(forKeys: entryKeys) else { return false }
                return v.isSymbolicLink != true && keep(v)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    struct FolderMeasure {
        var bytes: UInt64 = 0
        var newestModified: Date?
        var newestAccessed: Date?
        var capped = false
        var cancelled = false
    }

    /// Allocated size of everything under `folder`, hidden files included,
    /// never following a symlink. A Hugging Face snapshot is mostly links into
    /// its own `blobs` folder, so skipping links is also what stops the same
    /// weights being counted twice.
    static func measure(_ folder: URL, entryCap: Int, isCancelled: @Sendable () -> Bool) -> FolderMeasure {
        var m = FolderMeasure()
        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]
        let keySet = Set(keys)
        m.newestModified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: []) else { return m }
        var n = 0
        for case let url as URL in e {
            n += 1
            if n % 256 == 0, isCancelled() { m.cancelled = true; return m }
            if n > entryCap { m.capped = true; break }
            guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
            if v.isSymbolicLink == true { e.skipDescendants(); continue }
            if let d = v.contentModificationDate { m.newestModified = max(m.newestModified ?? d, d) }
            if v.isRegularFile == true {
                m.bytes += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                if let a = v.contentAccessDate { m.newestAccessed = max(m.newestAccessed ?? a, a) }
            }
        }
        return m
    }

    // MARK: - Ordering, sizes and wording

    /// Biggest first, by what moving the item frees.
    public static func sorted(_ items: [ModelItem]) -> [ModelItem] {
        items.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            let c = $0.name.localizedStandardCompare($1.name)
            return c != .orderedSame ? c == .orderedAscending : $0.url.path < $1.url.path
        }
    }

    /// What taking `selected` off the disk frees. Two Ollama models that share
    /// a blob free it only when both are in the selection, so this is not the
    /// sum of the rows.
    public static func freedBytes(_ selected: [ModelItem]) -> UInt64 {
        let ids = Set(selected.map(\.id))
        var counted = Set<String>()
        var total: UInt64 = 0
        for item in selected {
            guard item.source == .ollama else { total += item.bytes; continue }
            total += item.manifestBytes
            for blob in item.blobs where blob.owners.allSatisfy(ids.contains) {
                if counted.insert(item.root.path + "|" + blob.digest).inserted { total += blob.bytes }
            }
        }
        return total
    }

    /// "Not opened for 8 months", or "Modified 8 months ago" when there is no
    /// access date to go on. Same wording and same caveat as Large Files: the
    /// access date is only a hint, since a backup or an indexer can touch it.
    public static func ageText(for item: ModelItem, now: Date = Date()) -> String {
        guard let used = item.lastUsed else { return "Date unknown" }
        let days = max(0, Int(now.timeIntervalSince(used) / 86_400))
        if item.lastAccessed != nil {
            if days < 1 { return "Opened today" }
            return "Not opened for " + LargeFileScan.span(days: days)
        }
        if days < 1 { return "Modified today" }
        return "Modified " + LargeFileScan.span(days: days) + " ago"
    }

    /// The line under an Ollama model's path when it shares files with others.
    public static func sharedText(for item: ModelItem) -> String? {
        guard item.source == .ollama, item.sharedBytes > 0 else { return nil }
        return "\(fmtBytes(item.totalBytes)) in all, \(fmtBytes(item.sharedBytes)) shared with other models"
    }

    // MARK: - Moving to the Trash

    /// The path checks shared by every item, run on the path as it is on disk
    /// now. `base` is the folder the item must sit strictly inside and
    /// `depth` how many components it must be below it.
    private static func checkPath(
        _ url: URL, wantDirectory: Bool, base: URL, depth: Int
    ) -> (refusal: String?, modified: Date?) {
        let given = URL(fileURLWithPath: url.path)
        guard !given.pathComponents.contains("..") else { return ("odd path", nil) }

        // The link itself, not what it points at: resource values on a symlink
        // describe the link.
        guard let v = try? given.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey,
        ]) else { return ("no longer there", nil) }
        if v.isSymbolicLink == true { return ("a symlink", nil) }
        if wantDirectory {
            guard v.isDirectory == true else { return ("not a folder", nil) }
        } else {
            if v.isDirectory == true { return ("a folder, not a file", nil) }
            guard v.isRegularFile == true else { return ("not a regular file", nil) }
        }

        // If any part of the path is now a symlink, the real path differs from
        // the one the scan recorded, and this is not what was listed.
        let resolved = ProjectScan.canonical(given)
        guard resolved.path == given.path else { return ("a symlink is involved", nil) }

        guard ProjectScan.isInside(resolved, of: base) else {
            return ("outside the folders being scanned", nil)
        }
        let below = Array(resolved.pathComponents.dropFirst(base.pathComponents.count))
        guard below.count == depth else { return ("not where a model sits", nil) }
        if below.contains(where: { $0.hasPrefix(".") }) { return ("hidden", nil) }
        return (nil, v.contentModificationDate)
    }

    /// The last line of defence, run on every item immediately before it moves.
    ///
    /// The list was built minutes ago. In that time a symlink can replace a
    /// folder, a model can start downloading again, or a file can be rewritten.
    /// So everything is decided again against what is on disk now: the path
    /// must resolve to itself, still be the same kind of thing, sit inside a
    /// model folder at the depth a model sits, be unchanged since the scan, and
    /// not have changed in the last minute.
    ///
    /// For an Ollama manifest this checks the manifest only. The blobs that
    /// would go with it are checked when the move is planned.
    public static func verify(_ item: ModelItem, roots: [ModelRoot],
                              now: Date = Date()) -> ModelVerdict {
        let given = URL(fileURLWithPath: item.url.path)
        let resolved = ProjectScan.canonical(given)
        guard let root = roots.first(where: {
            $0.source == item.source && ProjectScan.isInside(resolved, of: $0.url)
        }) else {
            // Not inside a model folder as it stands. A path that is gone or a
            // link gets its own wording from the checks below.
            if (try? given.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return .refused("a symlink")
            }
            return .refused("outside the folders being scanned")
        }

        switch item.source {
        case .ollama:
            let check = checkPath(item.url, wantDirectory: false,
                                  base: root.url.appending(path: "manifests"), depth: 4)
            if let why = check.refusal { return .refused(why) }
            guard let modified = check.modified else { return .refused("no date") }
            if now.timeIntervalSince(modified) < recentWindow { return .tooRecent }
            if let listed = item.lastModified, abs(listed.timeIntervalSince(modified)) > 1 { return .tooRecent }
            return .ok

        case .huggingFace, .lmStudio:
            let depth = item.source == .huggingFace ? 1 : 2
            let check = checkPath(item.url, wantDirectory: true, base: root.url, depth: depth)
            if let why = check.refusal { return .refused(why) }
            if item.source == .huggingFace,
               huggingFaceName(resolved.lastPathComponent)?.kind != item.kind {
                return .refused("not a cache folder")
            }
            // A folder's own date barely moves while files inside it change, so
            // the newest date anywhere inside decides.
            let m = measure(resolved, entryCap: defaultMaxEntries, isCancelled: { false })
            guard let newest = m.newestModified else { return .refused("no date") }
            if now.timeIntervalSince(newest) < recentWindow { return .tooRecent }
            if let listed = item.lastModified, abs(listed.timeIntervalSince(newest)) > 1 { return .tooRecent }
            return .ok
        }
    }

    /// The real Trash call. Reversible: the item lands in the Trash with "Put
    /// Back" available. Never `removeItem`.
    public static func trashItem(_ url: URL) throws {
        try fm.trashItem(at: url, resultingItemURL: nil)
    }

    /// Moves each verified model to the Trash. `trash` is injectable so tests do
    /// not fill the real Trash.
    ///
    /// A folder model moves as one folder. An Ollama model moves its manifest
    /// and the blobs no remaining manifest names, which is what `ollama rm`
    /// frees. The manifests are read again here, so a model pulled since the
    /// scan keeps the blobs it shares.
    public static func moveToTrash(
        _ items: [ModelItem], roots: [ModelRoot], now: Date = Date(),
        trash: (URL) throws -> Void = ModelScan.trashItem
    ) -> ModelTrashResult {
        var out = ModelTrashResult()

        for item in items where item.source != .ollama {
            switch verify(item, roots: roots, now: now) {
            case .refused:
                out.refused.append(item.id)
            case .tooRecent:
                out.skippedRecent.append(item.id)
            case .ok:
                do {
                    try trash(item.url)
                    out.moved += 1
                    out.bytes += item.bytes
                    out.movedPaths.append(item.id)
                } catch {
                    out.failed.append(item.id)
                }
            }
        }

        // Ollama items are handled one model folder at a time, because blob
        // sharing is only meaningful inside one.
        var byRoot: [String: (root: ModelRoot, items: [ModelItem])] = [:]
        for item in items where item.source == .ollama {
            let resolved = ProjectScan.canonical(URL(fileURLWithPath: item.url.path))
            guard let root = roots.first(where: {
                $0.source == .ollama && ProjectScan.isInside(resolved, of: $0.url)
            }) else {
                out.refused.append(item.id)
                continue
            }
            byRoot[root.url.path, default: (root, [])].items.append(item)
        }
        for key in byRoot.keys.sorted() {
            guard let group = byRoot[key] else { continue }
            moveOllama(group.items, in: group.root, now: now, trash: trash, into: &out)
        }
        return out
    }

    private enum BlobState {
        case missing
        case ok(UInt64)
        case tooRecent
        case refused
    }

    /// The same checks as `verify`, for one blob.
    private static func verifyBlob(root: URL, digest: String, now: Date) -> BlobState {
        let url = blobURL(root: root, digest: digest)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != nil else {
            return .missing
        }
        let check = checkPath(url, wantDirectory: false, base: root.appending(path: "blobs"), depth: 1)
        if check.refusal != nil { return .refused }
        guard let modified = check.modified else { return .refused }
        if now.timeIntervalSince(modified) < recentWindow { return .tooRecent }
        guard let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
            return .refused
        }
        return .ok(UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0))
    }

    private static func moveOllama(
        _ items: [ModelItem], in root: ModelRoot, now: Date,
        trash: (URL) throws -> Void, into out: inout ModelTrashResult
    ) {
        // 1. Each manifest passes the path checks.
        var live: [String: ModelItem] = [:]
        for item in items {
            switch verify(item, roots: [root], now: now) {
            case .refused:   out.refused.append(item.id)
            case .tooRecent: out.skippedRecent.append(item.id)
            case .ok:        live[item.id] = item
            }
        }
        guard !live.isEmpty else { return }

        // A partial download written to in the last minute means a pull is
        // running, and it may be about to use a blob that is shared with these
        // models. Leave everything alone until it finishes.
        if downloadActive(root: root.url, now: now) {
            out.skippedRecent.append(contentsOf: live.keys.sorted())
            return
        }

        // 2. The manifests as they are now, including ones the list never had.
        let fresh = readOllamaManifests(root: root.url)
        let byPath = Dictionary(fresh.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        for id in live.keys.sorted() where byPath[id]?.valid != true {
            out.refused.append(id)
            live[id] = nil
        }
        let table = owners(of: fresh)

        /// The blobs that leave with `set`: named by one of its manifests and
        /// by no manifest outside it.
        func freed(by set: Set<String>) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for id in set {
                guard let m = byPath[id] else { continue }
                for d in m.digests where (table[d] ?? []).allSatisfy(set.contains) {
                    result[d, default: []].append(id)
                }
            }
            return result
        }

        // 3. Every blob that would move passes its own checks. One that fails
        // takes its models out of the move, which can make another shared blob
        // stay, so this repeats until nothing changes.
        while true {
            var drop: [String: ModelVerdict] = [:]
            for (digest, ids) in freed(by: Set(live.keys)) {
                switch verifyBlob(root: root.url, digest: digest, now: now) {
                case .missing, .ok: break
                case .tooRecent:    for id in ids { drop[id] = .tooRecent }
                case .refused:      for id in ids { drop[id] = .refused("blob") }
                }
            }
            if drop.isEmpty { break }
            for (id, why) in drop.sorted(by: { $0.key < $1.key }) {
                if why == .tooRecent { out.skippedRecent.append(id) } else { out.refused.append(id) }
                live[id] = nil
            }
        }

        // 4. Manifests first. If the run stops partway, an unlisted blob is
        // only wasted space, where a listed model with missing blobs is broken.
        var moved = Set<String>()
        for id in live.keys.sorted() {
            guard let item = live[id] else { continue }
            // Once more, right before the move.
            switch verify(item, roots: [root], now: now) {
            case .refused:   out.refused.append(id); continue
            case .tooRecent: out.skippedRecent.append(id); continue
            case .ok:        break
            }
            do {
                try trash(item.url)
                moved.insert(id)
                out.moved += 1
                out.bytes += item.manifestBytes
                out.movedPaths.append(id)
            } catch {
                out.failed.append(id)
            }
        }

        // 5. Then the blobs that nothing remaining names. A manifest that did
        // not move keeps its blobs, because it is not in `moved`.
        for digest in freed(by: moved).keys.sorted() {
            switch verifyBlob(root: root.url, digest: digest, now: now) {
            case .missing:
                continue
            case .tooRecent, .refused:
                // The model is already gone, so a file left behind is wasted
                // space, not a skipped model. It is reported as failed.
                out.failed.append(blobURL(root: root.url, digest: digest).path)
            case .ok(let bytes):
                let url = blobURL(root: root.url, digest: digest)
                do {
                    try trash(url)
                    out.bytes += bytes
                } catch {
                    out.failed.append(url.path)
                }
            }
        }
    }
}
