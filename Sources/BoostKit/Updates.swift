import AppKit
import Combine
import Sparkle

/// In-app updates, through Sparkle.
///
/// Before this, updating meant noticing a release on GitHub, deleting the old
/// app and installing the new one by hand, and most people never did. Sparkle
/// reads a small feed (`SUFeedURL` in Info.plist), and when it lists a newer
/// version it shows the release and an Install button.
///
/// What it does not do on its own, on purpose:
/// - It does not check anything until the person says yes. Sparkle asks on the
///   second launch, not the first, and nothing goes over the network before
///   that answer. Info.plist leaves `SUEnableAutomaticChecks` unset so that
///   prompt happens; setting it would decide for them.
/// - It never installs without a click. `SUAllowsAutomaticUpdates` is off in
///   Info.plist, which also removes the "install automatically" checkbox from
///   Sparkle's prompt.
/// - It sends no system profile. `SUEnableSystemProfiling` is never set.
///
/// Every download is checked against the EdDSA key in Info.plist
/// (`SUPublicEDKey`) before anything is replaced, so a feed or zip someone
/// tampered with is refused.
@MainActor
public final class Updates: ObservableObject {
    public static let shared = Updates()

    /// False while a check is already running, and always false in a build
    /// that has no feed. The menu item and the button follow it.
    @Published public private(set) var canCheck = false

    /// Sparkle stores this itself, in the app's defaults. Mirrored here so
    /// SwiftUI can bind a toggle to it.
    @Published public var automaticallyChecks = false {
        didSet {
            guard isRunning, automaticallyChecks != updater.automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    /// Whether this build can update itself at all. `swift run`, the snapshot
    /// mode and the test runner have no Info.plist with a feed, and starting
    /// Sparkle there only produces an error dialog about a missing SUFeedURL.
    public let isAvailable: Bool

    private let controller: SPUStandardUpdaterController
    private var isRunning = false
    private var watchers: Set<AnyCancellable> = []

    private var updater: SPUUpdater { controller.updater }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    /// Called once at launch. Starting the updater is not the same as checking:
    /// with automatic checks off, or not yet agreed to, it schedules nothing.
    public func start() {
        guard isAvailable, !isRunning else { return }
        controller.startUpdater()
        isRunning = true

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &watchers)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self, self.automaticallyChecks != value else { return }
                self.automaticallyChecks = value
            }
            .store(in: &watchers)
    }

    /// The "Check for Updates…" action. Boost is often in the background when
    /// this is clicked, because it was clicked from the menu bar popover or a
    /// Settings window that does not own focus, and Sparkle's window would then
    /// open behind whatever app is in front. So come forward first.
    public func checkForUpdates() {
        guard isRunning else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// When the last check finished, for the Settings window. Nil if never.
    public var lastChecked: Date? { isRunning ? updater.lastUpdateCheckDate : nil }
}
