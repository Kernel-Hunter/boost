import Testing
import Foundation
@testable import BoostKit

/// The rule engine decides on its own whether to interrupt you, and in one mode
/// whether to pause your apps. Both are worth pinning down.
@MainActor
@Suite("Rules", .serialized)
struct RulesTests {

    private let gb: UInt64 = 1_073_741_824

    private func fresh(threshold: Double = 2.0,
                       action: RuleAction = .notify) -> Rules {
        let r = Rules.shared
        r.enabled = true
        r.swapThresholdGB = threshold
        r.action = action
        r.resetForTesting()
        return r
    }

    @Test("Does nothing while switched off")
    func offMeansOff() {
        let r = Rules.shared
        r.enabled = false
        r.resetForTesting()
        #expect(!r.evaluate(swapBytes: 8 * gb, notify: { _ in }))
    }

    @Test("Stays quiet below the threshold")
    func quietBelowThreshold() {
        let r = fresh(threshold: 2.0)
        #expect(!r.evaluate(swapBytes: 1 * gb, notify: { _ in }))
    }

    @Test("Fires when swap crosses the line")
    func firesOnCrossing() {
        let r = fresh(threshold: 2.0)
        #expect(!r.evaluate(swapBytes: 1 * gb, notify: { _ in }))
        #expect(r.evaluate(swapBytes: 3 * gb, notify: { _ in }))
    }

    /// Opening the app on a Mac that has been struggling for an hour should not
    /// immediately announce a condition you can already see.
    @Test("Does not fire for a condition that was already true")
    func doesNotFireOnStartingOver() {
        let r = fresh(threshold: 2.0)
        // First reading is already over — that is a state, not an event.
        #expect(!r.evaluate(swapBytes: 5 * gb, notify: { _ in }))
    }

    /// A Mac sitting just over the line must not produce a notification every
    /// few seconds. That is how people learn to ignore them.
    @Test("Does not fire repeatedly while it stays over")
    func firesOnceWhileOver() {
        let r = fresh(threshold: 2.0)
        _ = r.evaluate(swapBytes: 1 * gb, notify: { _ in })
        #expect(r.evaluate(swapBytes: 3 * gb, notify: { _ in }))
        #expect(!r.evaluate(swapBytes: 3 * gb, notify: { _ in }))
        #expect(!r.evaluate(swapBytes: 4 * gb, notify: { _ in }))
    }

    @Test("Honours the cooldown even after dropping and rising again")
    func respectsCooldown() {
        let r = fresh(threshold: 2.0)
        let t0 = Date()
        _ = r.evaluate(swapBytes: 1 * gb, now: t0, notify: { _ in })
        #expect(r.evaluate(swapBytes: 3 * gb, now: t0, notify: { _ in }))

        // Falls back under and crosses again a minute later: still within the
        // cooldown, so still quiet.
        _ = r.evaluate(swapBytes: 0, now: t0.addingTimeInterval(60), notify: { _ in })
        #expect(!r.evaluate(swapBytes: 3 * gb, now: t0.addingTimeInterval(61), notify: { _ in }))

        // Well past the cooldown, it is allowed to speak again.
        _ = r.evaluate(swapBytes: 0, now: t0.addingTimeInterval(3600), notify: { _ in })
        #expect(r.evaluate(swapBytes: 3 * gb, now: t0.addingTimeInterval(3601), notify: { _ in }))
    }

    @Test("Only pauses when that is the action chosen")
    func pausesOnlyWhenAsked() {
        var paused = false

        let notifyOnly = fresh(threshold: 2.0, action: .notify)
        _ = notifyOnly.evaluate(swapBytes: 0, notify: { _ in })
        _ = notifyOnly.evaluate(swapBytes: 3 * gb, notify: { _ in }, pause: { paused = true })
        #expect(!paused, "the notify-only action must never touch your apps")

        let andPause = fresh(threshold: 2.0, action: .notifyAndPause)
        _ = andPause.evaluate(swapBytes: 0, notify: { _ in })
        _ = andPause.evaluate(swapBytes: 3 * gb, notify: { _ in }, pause: { paused = true })
        #expect(paused)
    }

    /// Closing is destructive and irreversible, so it is not on the menu at all.
    @Test("No rule can close an app")
    func noAutomaticClosing() {
        #expect(RuleAction.allCases.count == 2)
        #expect(!RuleAction.allCases.contains { $0.title.lowercased().contains("close") })
        #expect(!RuleAction.allCases.contains { $0.title.lowercased().contains("quit") })
    }
}
