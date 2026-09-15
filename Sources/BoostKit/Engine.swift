import AppKit
import ApplicationServices
import SwiftUI
import Darwin

@MainActor
public final class Engine: ObservableObject {

    @Published var items: [Item] = []
    @Published var mem = MemStats()
    @Published var selection: Set<String> = []
    @Published var keepList: Set<String> = []       // user-protected, shared with boost.sh
    private var keepNames: [String: String] = [:]   // id -> display name, for the shell script
    /// Backed by UserDefaults by hand, not @AppStorage — see autoQuitOnClose below
    /// for why: @AppStorage inside an ObservableObject doesn't reliably publish,
    /// and visibleItems (which reads this) needs to recompute when it changes.
    @Published var showSystem: Bool = UserDefaults.standard.bool(forKey: "showSystem") {
        didSet { UserDefaults.standard.set(showSystem, forKey: "showSystem") }
    }
    @Published var expanded: Set<Int> = [Category.app.rawValue, Category.agent.rawValue]
    @Published var search = ""
    @Published var lastReport: String?
    @Published var busy: String?
    @Published var confirmForce = false
    @Published var needsAccessibility = false

    /// Backed by UserDefaults by hand rather than @AppStorage, because @AppStorage
    /// inside an ObservableObject doesn't publish changes, and the permission
    /// banner has to react the moment this flips.
    @Published var autoQuitOnClose: Bool = UserDefaults.standard.bool(forKey: "autoQuitOnClose") {
        didSet {
            UserDefaults.standard.set(autoQuitOnClose, forKey: "autoQuitOnClose")
            applyAutoQuit(requesting: true)
        }
    }

    @AppStorage("resumeOnQuit") var resumeOnQuit = true
    /// Off by default, deliberately. Purging asks for your admin password to
    /// run /usr/sbin/purge as root, and what it does is throw away macOS's
    /// disk cache — the same cache this app's own header tells you is
    /// available memory, not waste. Dropping it makes "free" go up and the
    /// machine slower, because everything it discarded has to come off disk
    /// again. It is occasionally useful before a benchmark. It is not a
    /// routine part of reclaiming memory, and an app should not ask for root
    /// on your behalf by default.
    @AppStorage("purgeOnBoost") var purgeOnBoost = false

    private var timer: Timer?
    /// Things the user has explicitly unticked. Without this, newly launched apps
    /// could never be auto-ticked without also re-ticking what you just cleared.
    private var userDeselected: Set<String> = []

    static let supportDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Boost", isDirectory: true)
    private static let keepURL = supportDir.appendingPathComponent("keep.txt")

    public static let shared = Engine()

    init() {
        loadKeepList()
        // Safety net: never leave processes frozen because Boost went away.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Engine.shared.applicationWillTerminate() } }
        refresh()
        applyAutoQuit(requesting: false)   // restore the setting across launches
        startTimer(every: 2.0)
        for (name, interval) in [(NSApplication.didBecomeActiveNotification, 2.0),
                                 (NSApplication.didResignActiveNotification, 10.0)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Engine.shared.startTimer(every: interval) }
            }
        }
    }

    /// Two seconds while you're using it; ten in the background, to stay off the CPU
    /// it is supposed to be saving.
    private func startTimer(every interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - State

    /// Turns the watcher on or off, prompting for Accessibility the first time
    /// you enable it (never on launch — an unprompted permission dialog at
    /// startup is hostile).
    func applyAutoQuit(requesting: Bool) {
        WindowWatcher.shared.keepList = { Engine.shared.keepList }
        if autoQuitOnClose, !WindowWatcher.hasPermission, requesting {
            WindowWatcher.requestPermission()
        }
        needsAccessibility = autoQuitOnClose && !WindowWatcher.hasPermission
        WindowWatcher.shared.isEnabled = autoQuitOnClose && WindowWatcher.hasPermission
    }

    public func refresh() {
        mem = SystemScan.memory()
        if autoQuitOnClose {                       // you may grant access while we run
            let granted = WindowWatcher.hasPermission
            if needsAccessibility == granted { applyAutoQuit(requesting: false) }
        }
        items = SystemScan.buildItems()            // ~4 ms; cheap enough to stay on main
        let live = Set(items.map(\.id))
        selection.formIntersection(live)           // forget things that have exited
        // Tick anything new that qualifies, unless you deliberately unticked it.
        for item in defaultSelectable where !userDeselected.contains(item.id) {
            selection.insert(item.id)
        }
    }

    /// What Boost targets unless you say otherwise: your software, not Apple's.
    var defaultSelectable: [Item] {
        items.filter { item in
            guard !item.isProtected, !keepList.contains(item.baseID) else { return false }
            switch item.category {
            case .app:    return true               // anything with a window
            case .agent:  return !item.isAppleSoftware
            case .widget: return false              // cheap, and macOS respawns them
            case .system: return false
            }
        }
    }

    var visibleItems: [Item] {
        items.filter { item in
            if item.category == .system && !showSystem { return false }
            if item.isProtected && !showSystem { return false }
            if search.isEmpty { return true }
            return item.name.localizedCaseInsensitiveContains(search)
        }
    }

    func items(in category: Category) -> [Item] {
        visibleItems.filter { $0.category == category }
    }

    var pausedItems: [Item] { items.filter(\.isPaused) }
    var selectedItems: [Item] {
        visibleItems.filter { selection.contains($0.id) && !$0.isProtected && !keepList.contains($0.baseID) }
    }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.rssBytes } }

    func isExpanded(_ c: Category) -> Bool { expanded.contains(c.rawValue) }
    func toggleExpanded(_ c: Category) {
        if expanded.contains(c.rawValue) { expanded.remove(c.rawValue) } else { expanded.insert(c.rawValue) }
    }

    func isSelected(_ item: Item) -> Bool { selection.contains(item.id) }
    func toggle(_ item: Item) {
        if selection.contains(item.id) {
            selection.remove(item.id); userDeselected.insert(item.id)
        } else {
            selection.insert(item.id); userDeselected.remove(item.id)
        }
    }
    func setSelection(_ on: Bool, for category: Category) {
        let ids = items(in: category).filter { !$0.isProtected && !keepList.contains($0.baseID) }.map(\.id)
        if on { selection.formUnion(ids); userDeselected.subtract(ids) }
        else  { selection.subtract(ids); userDeselected.formUnion(ids) }
    }

    // MARK: - Keep list (shared with the shell script)

    func isKept(_ item: Item) -> Bool { keepList.contains(item.baseID) }
    func toggleKeep(_ item: Item) {
        if keepList.contains(item.baseID) {
            keepList.remove(item.baseID); keepNames[item.baseID] = nil
        } else {
            keepList.insert(item.baseID); keepNames[item.baseID] = item.name
            selection.remove(item.id); userDeselected.insert(item.id)
        }
        saveKeepList()
    }

    /// Line format is "<bundle id>\t<display name>": Boost.app matches on the id,
    /// boost.sh matches on the name. One file, both readers.
    private func loadKeepList() {
        guard let text = try? String(contentsOf: Self.keepURL, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let cols = line.split(separator: "\t", maxSplits: 1).map(String.init)
            keepList.insert(cols[0])
            if cols.count > 1 { keepNames[cols[0]] = cols[1] }
        }
    }

    private func saveKeepList() {
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        let rows = keepList.sorted().map { id -> String in
            "\(id)\t\(keepNames[id] ?? (id as NSString).lastPathComponent)"
        }
        let body = (["# Boost keep list — never close these.",
                     "# <bundle id><TAB><name>.  Boost.app reads column 1, boost.sh reads column 2.",
                     ""] + rows).joined(separator: "\n") + "\n"
        try? body.write(to: Self.keepURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Actions

    /// SIGSTOP freezes a process at zero CPU without destroying its state.
    /// Parent first, so it cannot spawn a child that escapes the freeze.
    func pause(_ item: Item) {
        guard !item.isProtected else { return }
        for pid in item.pids { kill(pid, SIGSTOP) }
    }

    /// Children first, then parent — the reverse of pausing.
    func resume(_ item: Item) {
        for pid in item.pids.reversed() { kill(pid, SIGCONT) }
    }

    func quit(_ item: Item, force: Bool = false) {
        guard !item.isProtected else { return }
        // A paused process cannot process a quit request — wake it first.
        if item.isPaused { resume(item) }

        sendQuit(item, force: force)

        // Some apps (Spotify, YT Music) accept a polite quit — the music
        // stops — and then just never actually exit. Every call site goes
        // through here, so this is the one place that can follow up.
        guard !force else { return }
        let baseID = item.baseID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.refresh()
            guard let stillHere = self.items.first(where: { $0.baseID == baseID }) else { return }
            // Only escalate against an app showing nothing. An app still
            // holding a window after a quit request is asking you something —
            // "Save changes before closing?" is itself a window — and killing
            // it there destroys exactly the work the prompt existed to save.
            // An app that is genuinely just refusing to leave has none.
            guard self.hasNothingOnScreen(stillHere) else { return }
            self.sendQuit(stillHere, force: true)
        }
    }

    /// True when the app has nothing on screen — no window that is actually
    /// showing. A "Save changes?" sheet is a visible window and stops us; a
    /// merely minimised window is not asking anything and does not.
    ///
    /// Unreadable (no Accessibility permission, or a process we can't inspect)
    /// counts as "something is showing", so we never force on a guess.
    private func hasNothingOnScreen(_ item: Item) -> Bool {
        guard let pid = item.runningAppPID else { return false }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return false }
        return !windows.contains { w in
            var mini: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini)
            return (mini as? Bool) != true      // a visible (non-minimised) window
        }
    }

    private func sendQuit(_ item: Item, force: Bool) {
        if let pid = item.runningAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            if force { app.forceTerminate() } else { app.terminate() }
        } else {
            for pid in item.pids { kill(pid, force ? SIGKILL : SIGTERM) }
        }
    }

    func pauseSelected() {
        let targets = selectedItems.filter { !$0.isPaused }
        for item in targets { pause(item) }
        report("Paused \(targets.count) \(targets.count == 1 ? "item" : "items") — zero CPU, state kept. Resume any time.")
        refresh()
    }

    /// Sweeps the whole system for suspended processes, not just ones we paused —
    /// so nothing can get stranded frozen if Boost was quit or crashed.
    public func resumeEverything() {
        let procs = SystemScan.sampleProcesses()
        var woken = 0
        for (pid, s) in procs where s.stopped {
            if kill(pid, SIGCONT) == 0 { woken += 1 }
        }
        report(woken == 0 ? "Nothing was paused." : "Resumed \(woken) \(woken == 1 ? "process" : "processes").")
        refresh()
    }

    func quitSelected(force: Bool = false) {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let before = SystemScan.memory()
        for item in targets { quit(item, force: force) }

        busy = "Closing \(targets.count)…"
        Task {
            // quit(_:) itself follows up on anything that ignores a polite
            // request (Spotify, YT Music) with a forced one ~2.5s in — so
            // this just needs to wait past that before judging who's left.
            try? await Task.sleep(nanoseconds: force ? 2_500_000_000 : 4_500_000_000)

            var purgeNote = ""
            if purgeOnBoost { purgeNote = await Self.purgeCaches() }
            await MainActor.run {
                self.busy = nil
                self.refresh()
                let fresh = self.items
                let after = self.mem
                let freed = Int64(after.free &+ after.cached) - Int64(before.free &+ before.cached)
                let targetIDs = Set(targets.map(\.id))
                let survivors = fresh.filter { targetIDs.contains($0.id) }
                var msg = "Closed \(targets.count - survivors.count) of \(targets.count)."
                if freed > 0 { msg += " Reclaimed \(fmtBytes(UInt64(freed)))." }
                if !survivors.isEmpty {
                    msg += " Still open (probably asking to save): "
                        + survivors.map(\.name).joined(separator: ", ") + "."
                }
                if !purgeNote.isEmpty { msg += " " + purgeNote }
                self.report(msg)
            }
        }
    }

    /// Frees memory without closing anything, and then tells you the truth about
    /// what that achieved.
    ///
    /// The only lever macOS gives you here is `purge`, which drops the file
    /// cache. That number moves — often by gigabytes — and it is mostly
    /// theatre: the cache was *available* memory already, and everything thrown
    /// away has to be read off disk again, so the Mac is briefly slower for it.
    /// Every "free up RAM" utility is doing this, and none of them say so.
    ///
    /// So it measures before and after and reports what actually changed,
    /// including when the honest answer is that nothing worth having was
    /// gained. If you want memory back and you want to keep it, Pause is the
    /// button that does that.
    func freeMemory() {
        guard busy == nil else { return }
        busy = "Freeing…"
        let before = SystemScan.memory()

        Task {
            let note = await Self.purgeCaches()
            await MainActor.run {
                self.busy = nil
                self.refresh()
                let after = self.mem

                guard note.hasPrefix("Disk cache purged") else {
                    self.report(note)       // cancelled at the password prompt, or unavailable
                    return
                }

                // `used` is what the header calls in use. Cached moving is not a
                // win on its own, so it is reported separately rather than
                // folded into one flattering figure.
                let usedFreed = before.used > after.used ? before.used - after.used : 0
                let cacheDropped = before.cached > after.cached ? before.cached - after.cached : 0

                if usedFreed >= 100 * 1_048_576 {
                    self.report("Freed \(fmtBytes(usedFreed)) of memory in use.")
                } else if cacheDropped > 0 {
                    self.report("Dropped \(fmtBytes(cacheDropped)) of disk cache. "
                              + "That memory was already available — the Mac will be "
                              + "briefly slower while it reads it back.")
                } else {
                    self.report("Nothing to free. Your Mac was not holding anything back.")
                }
            }
        }
    }

    /// `purge` needs root, so this raises the standard macOS authentication sheet.
    nonisolated static func purgeCaches() async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let script = "do shell script \"/usr/sbin/purge\" with administrator privileges"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run(); p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0 ? "Disk cache purged." : "Cache purge skipped.")
                } catch {
                    cont.resume(returning: "Cache purge unavailable.")
                }
            }
        }
    }

    private func report(_ s: String) {
        lastReport = s
        Task {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            await MainActor.run { if self.lastReport == s { self.lastReport = nil } }
        }
    }

    func applicationWillTerminate() {
        guard resumeOnQuit else { return }
        let procs = SystemScan.sampleProcesses()
        for (pid, s) in procs where s.stopped { kill(pid, SIGCONT) }
    }
}
