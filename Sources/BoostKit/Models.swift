import AppKit

// MARK: - Raw process sample

struct ProcSample {
    let pid: pid_t
    let ppid: pid_t
    let rssBytes: UInt64
    let rssKnown: Bool     // false for root-owned processes we may not inspect
    let cpu: Double
    let stopped: Bool      // p_stat == SSTOP — suspended by SIGSTOP
    let path: String
}

// MARK: - Grouping

enum Category: Int, CaseIterable, Identifiable {
    case app, agent, widget, system
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .app:    return "Apps"
        case .agent:  return "Menu Bar & Background"
        case .widget: return "Widgets"
        case .system: return "System"
        }
    }
    var symbol: String {
        switch self {
        case .app:    return "macwindow"
        case .agent:  return "menubar.rectangle"
        case .widget: return "square.grid.2x2"
        case .system: return "gearshape.2"
        }
    }
    var blurb: String {
        switch self {
        case .app:    return "Apps with windows"
        case .agent:  return "No windows, still running"
        case .widget: return "Desktop and Notification Centre widgets"
        case .system: return "macOS internals. Leave these alone unless you know why"
        }
    }
}

// MARK: - Sorting

/// How the process list within each category is ordered. Size-descending was
/// the only option before this — fixed at the point items were built, with
/// no way to ask for anything else.
enum SortOption: String, CaseIterable, Identifiable {
    case size, name, cpu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: return "Memory"
        case .name: return "Name"
        case .cpu:  return "CPU"
        }
    }
    var symbol: String {
        switch self {
        case .size: return "memorychip"
        case .name: return "textformat"
        case .cpu:  return "cpu"
        }
    }
}

// MARK: - A thing the user can act on

struct Item: Identifiable, Equatable {
    /// Stable across launches — bundle id, or executable path. Used for the keep list.
    let baseID: String
    /// Unique per row. Equals baseID unless several live processes share it
    /// (three `python` helpers, four QuickLook services…), in which case the pid
    /// is appended. Duplicate Identifiable ids break ForEach and make one tick
    /// select every twin, so this must be unique.
    var id: String
    var name: String
    var category: Category
    var isAppleSoftware: Bool
    var pids: [pid_t]           // every process this item owns, root first
    var rssBytes: UInt64
    var rssKnown: Bool
    var cpu: Double
    var isPaused: Bool
    var bundlePath: String?
    var runningAppPID: pid_t?   // set when NSRunningApplication can terminate it politely

    /// Never quit or pause these — the Mac's UI is built out of them.
    var isProtected: Bool { Guard.isProtected(id: baseID, name: name) }

    var processCount: Int { pids.count }

    static func == (a: Item, b: Item) -> Bool {
        a.id == b.id && a.pids == b.pids && a.rssBytes == b.rssBytes
            && a.isPaused == b.isPaused && abs(a.cpu - b.cpu) < 0.05
    }
}

// MARK: - Safety

enum Guard {
    /// Quitting or suspending any of these takes the desktop down with it.
    /// This list is absolute: it is not overridable from the UI.
    private static let bundleIDs: Set<String> = [
        "com.apple.WindowManager", "com.apple.dock", "com.apple.dock.extra",
        "com.apple.finder", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.talagent",
        "com.apple.systemevents", "com.apple.wallpaper.agent", "com.apple.Spotlight",
        "com.apple.coreservices.uiagent", "com.apple.universalcontrol",
        "com.apple.AccessibilityUIServer", "com.apple.UserNotificationCenter",
        "com.apple.security.Keychain-Circle-Notification", "com.apple.LocalAuthentication.UIAgent",
        "boost.local.app",
    ]

    private static let execNames: Set<String> = [
        "WindowServer", "launchd", "kernel_task", "loginwindow", "coreaudiod",
        "logind", "UserEventAgent", "cfprefsd", "distnoted", "opendirectoryd",
        "securityd", "syslogd", "notifyd", "diskarbitrationd", "configd",
        "powerd", "hidd", "Dock", "Finder", "SystemUIServer", "Boost",
    ]

    static func isProtected(id: String, name: String) -> Bool {
        if bundleIDs.contains(id) { return true }
        let leaf = (id as NSString).lastPathComponent
        if execNames.contains(leaf) || execNames.contains(name) { return true }
        return false
    }

    /// Anything shipped inside the OS is hidden by default and never auto-selected.
    static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/bin/") || path.hasPrefix("/Library/Apple/")
    }
}

// MARK: - Memory

struct MemStats {
    var total: UInt64 = 0
    var used: UInt64 = 0          // app + wired + compressed
    var cached: UInt64 = 0        // inactive + purgeable + speculative — reclaimable
    var free: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0

    /// Fraction of RAM genuinely spoken for. This is the number worth watching.
    var pressure: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(used) / Double(total))
    }

    enum Level { case easy, moderate, tight }
    var level: Level {
        if swapUsed > 1_073_741_824 || pressure > 0.90 { return .tight }
        if swapUsed > 0 || pressure > 0.75 { return .moderate }
        return .easy
    }
}

func fmtBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    let mb = Double(b) / 1_048_576
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return "\(b) B"
}

/// One decimal under 10%, where an idle Mac's real activity actually lives —
/// rounding 0.1–9.9% down to a flat integer made almost every row read "0%".
func fmtCPU(_ percent: Double) -> String {
    percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent))%"
}
