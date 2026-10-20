import AppKit
import Foundation

/// Freezes apps you chose, once you have left them alone for a while, and wakes
/// them the moment you switch back.
///
/// This is the free version of what App Tamer does for money, with the same
/// rules Boost applies everywhere else: it only touches apps you listed, never
/// closes anything, and pausing is the one action it takes, which is reversible
/// and is undone by looking at the app.
@MainActor
public final class AutoPause: ObservableObject {
    public static let shared = AutoPause()

    public static let idleChoices = [5, 10, 15, 30, 60]

    /// An app doing real work, such as compiling or exporting, is not idle even
    /// when it is in the background. Playing audio or video, a call and many
    /// downloads show up as a power assertion rather than as CPU, so those
    /// are checked separately.
    static let busyCPU = 3.0

    @Published public var enabled: Bool = UserDefaults.standard.bool(forKey: "autoPauseEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "autoPauseEnabled")
            if !enabled { wakeSleeping() }
        }
    }

    @Published public var idleMinutes: Int =
        UserDefaults.standard.object(forKey: "autoPauseIdleMinutes") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: "autoPauseIdleMinutes") }
    }

    /// Bundle id to display name, so Settings can show what is listed even
    /// while the app is not running.
    @Published public private(set) var listed: [String: String] = AutoPause.loadListed()

    private var lastActive: [String: Date] = [:]
    private(set) var sleeping: Set<String> = []

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            MainActor.assumeIsolated { AutoPause.shared.activated(id) }
        }
    }

    // MARK: - The list

    func isListed(_ item: Item) -> Bool { listed[item.baseID] != nil }

    func toggle(_ item: Item) {
        guard !item.isProtected else { return }
        if listed[item.baseID] != nil { listed[item.baseID] = nil } else { listed[item.baseID] = item.name }
        Self.saveListed(listed)
    }

    public func remove(_ id: String) {
        listed[id] = nil
        Self.saveListed(listed)
    }

    private static func loadListed() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "autoPauseApps"),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private static func saveListed(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: "autoPauseApps")
        }
    }

    // MARK: - Decision

    /// The apps that should be paused right now. Pure, so the rules that decide
    /// whether to freeze somebody's app can be tested without any app running.
    static func candidates(items: [Item], listed: Set<String>, lastActive: [String: Date],
                           frontmost: String?, now: Date, idle: TimeInterval,
                           awake: Set<pid_t> = []) -> [Item] {
        items.filter { item in
            guard listed.contains(item.baseID),
                  !item.isProtected,
                  !item.isPaused,
                  item.baseID != frontmost,
                  item.cpu < busyCPU,
                  awake.isDisjoint(with: item.pids),
                  let seen = lastActive[item.baseID] else { return false }
            return now.timeIntervalSince(seen) >= idle
        }
    }

    // MARK: - Running

    /// Called on every refresh.
    func tick(items: [Item], engine: Engine, now: Date = Date()) {
        guard enabled else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // An app is first seen now, so a fresh launch of Boost gives every
        // listed app a full idle period instead of freezing them at once.
        for item in items where listed[item.baseID] != nil && lastActive[item.baseID] == nil {
            lastActive[item.baseID] = now
        }
        if let frontmost { lastActive[frontmost] = now }

        // Resumed by hand: treat it as used, or the next tick would freeze it again.
        for id in sleeping where !items.contains(where: { $0.baseID == id && $0.isPaused }) {
            lastActive[id] = now
            sleeping.remove(id)
        }

        guard engine.busy == nil else { return }
        let due = Self.candidates(items: items, listed: Set(listed.keys), lastActive: lastActive,
                                  frontmost: frontmost, now: now,
                                  idle: TimeInterval(idleMinutes * 60),
                                  awake: PowerAssertions.busyPIDs())
        for item in due {
            engine.pause(item)
            sleeping.insert(item.baseID)
        }
    }

    private func activated(_ id: String) {
        lastActive[id] = Date()
        // A listed app can be frozen without being in `sleeping`, for example
        // after Boost was relaunched with "leave paused on quit". Waking it is
        // right either way: nobody wants to switch to a frozen window.
        let wasSleeping = sleeping.remove(id) != nil
        guard wasSleeping || listed[id] != nil else { return }
        // A fresh scan, not engine.items: that snapshot can predate the pause,
        // and an app it still shows as running would be left frozen.
        let engine = Engine.shared
        var woke = false
        for item in SystemScan.buildItems() where item.baseID == id && item.isPaused {
            engine.resume(item)
            woke = true
        }
        if woke || wasSleeping { engine.refresh() }
    }

    private func wakeSleeping() {
        let engine = Engine.shared
        for item in SystemScan.buildItems() where sleeping.contains(item.baseID) && item.isPaused {
            engine.resume(item)
        }
        sleeping.removeAll()
        engine.refresh()
    }
}
