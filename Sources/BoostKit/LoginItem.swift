import Foundation
import ServiceManagement

/// Start at login, through the system's own login item list.
///
/// Registered with SMAppService, so it appears in System Settings under Login
/// Items where it can be switched off without opening Boost. macOS can refuse,
/// most often when the app is not in /Applications, and the refusal is shown
/// as it is rather than swallowed.
@MainActor
public final class LoginItemModel: ObservableObject {
    @Published public private(set) var enabled: Bool
    @Published public private(set) var problem: String?

    public init() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    public func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = "macOS would not allow it: \(error.localizedDescription)"
        }
        enabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            problem = "Allow Boost under System Settings, General, Login Items."
        }
    }
}
