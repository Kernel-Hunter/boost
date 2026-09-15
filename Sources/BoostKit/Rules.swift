import Foundation
import UserNotifications

/// Watches memory and reacts on its own.
///
/// The obvious version of this feature closes your apps for you when memory
/// gets tight. That is a bad idea and it is worth being explicit about why: the
/// moment memory is tight is the moment you have the most open, and an app that
/// silently quits things in the background will eventually do it in the middle
/// of something. Worse, you would not know it had — you would just find work
/// missing and have no reason to suspect the memory utility.
///
/// So the default action is to tell you. Acting is opt-in, and the only action
/// offered is Pause, which is reversible. Closing is never automatic.
public enum RuleAction: String, CaseIterable, Sendable {
    case notify
    case notifyAndPause

    public var title: String {
        switch self {
        case .notify:         return "Tell me"
        case .notifyAndPause: return "Tell me and pause what's ticked"
        }
    }
}

@MainActor
public final class Rules: ObservableObject {
    public static let shared = Rules()

    /// Off until asked for. An app that starts watching and notifying on first
    /// launch has decided something on your behalf.
    /// Setting this only records the choice. Asking macOS for permission to
    /// notify is a separate call the UI makes, because a property setter that
    /// puts up a system dialog is a surprise, and because it makes this whole
    /// type testable without an app bundle around it.
    @Published public var enabled: Bool = UserDefaults.standard.bool(forKey: "rulesEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "rulesEnabled") }
    }

    /// Swap, in gigabytes, past which something is said. Swap rather than used
    /// memory because used memory being high is normal and swap climbing is
    /// the thing that actually makes a Mac feel slow.
    @Published public var swapThresholdGB: Double =
        UserDefaults.standard.object(forKey: "swapThresholdGB") as? Double ?? 2.0 {
        didSet { UserDefaults.standard.set(swapThresholdGB, forKey: "swapThresholdGB") }
    }

    @Published public var action: RuleAction =
        RuleAction(rawValue: UserDefaults.standard.string(forKey: "ruleAction") ?? "")
        ?? .notify {
        didSet { UserDefaults.standard.set(action.rawValue, forKey: "ruleAction") }
    }

    /// Long enough that a Mac sitting just over the line does not produce a
    /// notification every few seconds, which is how people learn to ignore
    /// them and then turn the feature off.
    public var cooldown: TimeInterval = 15 * 60
    private var lastFired: Date?

    /// Only fires on the way *through* the threshold. Without this, opening the
    /// app on an already-struggling Mac would immediately notify about a
    /// condition that has been true for an hour and that you can see.
    private var wasOver = false

    /// Whether we have a previous reading to compare against. The first
    /// observation establishes a baseline and never fires: there is no edge to
    /// have crossed when you have only seen one side of it.
    private var hasBaseline = false

    private init() {}

    // MARK: - Evaluation

    /// Called on every refresh. Decides whether this is a moment worth speaking
    /// about, and returns whether it did.
    ///
    /// Both effects are injected rather than called directly. That keeps the
    /// decision — a small state machine about thresholds, edges and cooldowns,
    /// which is the part that can be wrong — testable without a notification
    /// centre or a running app. `UNUserNotificationCenter` aborts the process
    /// outright when there is no app bundle around it, so a test that called
    /// the real one would not fail, it would take the whole suite with it.
    @discardableResult
    public func evaluate(swapBytes: UInt64, now: Date = Date(),
                         notify: ((UInt64) -> Void)? = nil,
                         pause: () -> Void = {}) -> Bool {
        guard enabled else { wasOver = false; hasBaseline = false; return false }

        let threshold = UInt64(swapThresholdGB * 1_073_741_824)
        let isOver = swapBytes >= threshold
        let hadBaseline = hasBaseline
        defer { wasOver = isOver; hasBaseline = true }

        guard hadBaseline else { return false }      // first reading is a baseline
        guard isOver, !wasOver else { return false }
        if let last = lastFired, now.timeIntervalSince(last) < cooldown { return false }
        lastFired = now

        (notify ?? { self.postNotification(swapBytes: $0) })(swapBytes)
        if action == .notifyAndPause { pause() }
        return true
    }

    /// Exposed so tests can drive the state machine without a clock.
    func resetForTesting() {
        wasOver = false
        hasBaseline = false
        lastFired = nil
    }

    // MARK: - Notifications

    /// Called by the UI when the rule is switched on, never from a setter.
    public func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(swapBytes: UInt64) {
        let content = UNMutableNotificationContent()
        content.title = "Your Mac is paging to disk"
        content.body = "\(fmtBytes(swapBytes)) of swap in use. "
                     + (action == .notifyAndPause
                        ? "Paused what was ticked in Boost."
                        : "Open Boost to free some memory.")
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
