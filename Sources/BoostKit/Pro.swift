import Foundation

/// The seam where paid features will attach.
///
/// Nothing is gated today and this deliberately unlocks everything. It exists so
/// that the first paid feature is a one-line `guard` rather than a refactor, and
/// so the rules for what may be gated are written down before there is any
/// revenue to argue with.
///
/// ## What may never be behind a paywall
///
/// - **Anything that protects you from this app.** The guard list, the disk
///   cleaner's allowlist, the refusal to force-quit an app showing a save
///   prompt. Safety is not a tier.
/// - **Anything already free.** A feature that ships free and is later moved
///   behind a subscription is a betrayal of the people who adopted it, and on a
///   GPL codebase it is also pointless — the last free build is still there.
/// - **Honesty.** The memory readings, the trend line, the explanation that
///   cached memory is available. An app that tells you the truth only if you pay
///   is selling the lie.
///
/// ## What reasonably may be
///
/// Ongoing work and convenience: sync across machines, longer history retention,
/// exportable reports, scheduled automation. Things that cost to run, or that a
/// heavy user wants and a casual one does not.
///
/// ## Why the check is honest rather than clever
///
/// This is GPL-3 source. Anyone can delete the check and rebuild, and no amount
/// of obfuscation changes that — it only makes the code worse for the people
/// reading it honestly. So the check is a plain boolean, and the business model
/// rests on the build being notarized, signed, kept up to date and supported,
/// which is the part that actually costs something to provide.
///
/// It performs no network access and phones nothing home. When a licence check
/// arrives it will be a local receipt check, and it will be documented here.
public enum Pro {

    /// Features that might one day be paid. Listing one here does not gate it.
    public enum Feature: String, CaseIterable, Sendable {
        case unlimitedHistory
        case scheduledAutomation
        case reportExport
    }

    /// True for everything, today.
    ///
    /// Boost is free. When that changes it will change here, and the commit that
    /// does it will say which features moved and why — not slide it into a
    /// release note.
    public static func isUnlocked(_ feature: Feature) -> Bool { true }

    /// Whether any paid tier exists at all. Used by the UI to decide whether to
    /// show anything about it; false means the word "Pro" never appears, which
    /// is the correct amount of upsell in an app with nothing to sell.
    public static var tierExists: Bool { false }
}
