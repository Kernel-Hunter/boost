import AppKit
import ApplicationServices

/// Makes the red close button behave like "quit": when an app's last window goes
/// away, quit the app.
///
/// macOS deliberately keeps an app alive with no windows so ⌘N is instant. This
/// opts individual apps out of that.
///
/// Window counts come from the Accessibility API rather than CGWindowList,
/// because a *minimised* window still counts as a window there. CGWindowList's
/// on-screen list drops minimised windows, which would make minimising an app
/// quit it — and its full list counts hidden internal panels (TextEdit reports
/// seven windows for one document), so neither variant is usable here.
///
/// That means Spotify and other Electron-shell apps, whose red button
/// minimises the window rather than destroying it, are NOT reached by this
/// feature at all — deliberately: the alternative is minimising any app's
/// last window quitting it, which is a worse trade for everything else. Close
/// those by hand (Dock icon → Quit, or Boost's own list).
@MainActor
final class WindowWatcher {
    static let shared = WindowWatcher()

    /// How long an app must sit at zero windows before it is quit. Covers the
    /// moment between closing one document and opening the next.
    var settleDelay: TimeInterval = 2.0
    /// Apps legitimately have no windows while starting up.
    var launchGrace: TimeInterval = 8.0
    /// Apps the user pinned. Injected so this class stands alone.
    var keepList: () -> Set<String> = { [] }
    /// Called whenever an app is quit, for logging in tests and the UI.
    var onQuit: (String) -> Void = { _ in }

    private var timer: Timer?
    private var startedAt: Date?
    private var emptySince: [pid_t: Date] = [:]
    /// Apps we have actually seen holding a window. Only matters during the
    /// startup grace window right after watching begins: an app that already
    /// had none right then (a windowless Terminal, say) gets left alone for a
    /// beat rather than judged for a "closing" it never did in front of us.
    /// That immunity is not permanent — Spotify or a Safari web app commonly
    /// sit at zero windows (playing in the background) at the exact moment
    /// Boost starts, and the point of this feature is that closing their
    /// window quits them, same as any other app. Once the grace window has
    /// passed, everyone is judged purely on "is it empty right now", history
    /// or not.
    private var everHadWindows: Set<pid_t> = []

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    // MARK: - Permission

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and deep-links to Settings. Harmless if already granted.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: - Watching

    private func start() {
        timer?.invalidate()
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        emptySince.removeAll()
        everHadWindows.removeAll()
    }

    private func windowCount(_ pid: pid_t) -> Int? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }
        return windows.count
    }

    private func tick() {
        guard Self.hasPermission else { return }
        let now = Date()
        var seen = Set<pid_t>()

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            let pid = app.processIdentifier
            let name = app.localizedName ?? ""
            let id = app.bundleIdentifier ?? name

            if Guard.isProtected(id: id, name: name) { continue }   // Finder, Boost, the desktop
            if keepList().contains(id) { continue }                  // you pinned it
            if let launched = app.launchDate, now.timeIntervalSince(launched) < launchGrace { continue }

            seen.insert(pid)
            guard let count = windowCount(pid) else { continue }    // unreadable: leave it alone

            if count > 0 {
                emptySince[pid] = nil
                everHadWindows.insert(pid)
                continue
            }
            // Never seen it with a window — only a pass during the initial
            // grace window. Past that, it's judged like everything else.
            if !everHadWindows.contains(pid) {
                let sinceStart = startedAt.map { now.timeIntervalSince($0) } ?? .infinity
                if sinceStart < launchGrace { continue }
            }

            if let since = emptySince[pid] {
                if now.timeIntervalSince(since) >= settleDelay {
                    emptySince[pid] = nil
                    onQuit(name)
                    // Unrefusable, straight away — not a lesser version of a
                    // real quit. By the time an app's window count is genuinely
                    // zero, the close has already fully happened: if there was
                    // anything unsaved, macOS already put up that sheet and the
                    // window would still be here. There is nothing left for a
                    // polite terminate() to protect, only apps (Spotify, YT
                    // Music) that accept it, stop what they're doing, and then
                    // just never exit — which is what made this feel broken.
                    app.forceTerminate()
                }
            } else {
                emptySince[pid] = now
            }
        }
        emptySince = emptySince.filter { seen.contains($0.key) }
        everHadWindows.formIntersection(seen)
    }
}
