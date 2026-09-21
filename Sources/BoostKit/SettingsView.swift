import SwiftUI

/// The app's real Settings window (⌘,), rather than configuration buried in
/// a footer overflow menu. Everything here was already a setting before —
/// this just gives it a place a person would actually expect to find it.
public struct BoostSettingsView: View {
    @ObservedObject var engine: Engine = .shared
    @ObservedObject private var rules = Rules.shared

    public init() {}

    public var body: some View {
        Form {
            Section("Window & Shortcuts") {
                Toggle("Close button quits the app", isOn: $engine.autoQuitOnClose)
                Toggle("Global shortcut (⌥⌘B)", isOn: $engine.globalHotkey)
                    .help("Opens Boost and closes what is ticked, from any app.")
                Toggle("Resume everything when Boost quits", isOn: $engine.resumeOnQuit)
                    .help("Nothing is ever left frozen because Boost went away.")
            }

            Section("Free Memory") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Reclaim more aggressively", isOn: $engine.aggressiveReclaim)
                    Text("Pushes memory_pressure to `critical` instead of `warn`. It "
                        + "can reclaim more, and it can also be the reason the kernel "
                        + "decides to kill something on its own — with no dialog from "
                        + "Boost, no warning first. The instant-stop on swap growth "
                        + "still runs; it just isn't guaranteed to catch this in time. "
                        + "Off is the setting for almost everyone.")
                        .font(.caption)
                        .foregroundStyle(engine.aggressiveReclaim ? .orange : .secondary)
                }
                Toggle("Also purge disk cache", isOn: $engine.purgeOnBoost)
                    .help("Asks for your admin password and drops macOS's disk "
                        + "cache. Makes free memory look higher and the Mac "
                        + "briefly slower. Rarely worth it, so it is off by default.")
            }

            Section("Alerts") {
                Toggle("Warn me when swap climbs", isOn: Binding(
                    get: { rules.enabled },
                    set: { on in
                        rules.enabled = on
                        if on { rules.requestPermission() }
                    }
                ))
                .help("Swap is the number that means your Mac has actually run out, "
                    + "rather than merely being busy.")

                if rules.enabled {
                    Picker("Past", selection: $rules.swapThresholdGB) {
                        Text("1 GB of swap").tag(1.0)
                        Text("2 GB of swap").tag(2.0)
                        Text("4 GB of swap").tag(4.0)
                    }
                    Picker("Then", selection: $rules.action) {
                        ForEach(RuleAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
