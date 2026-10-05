import SwiftUI

/// The app's real Settings window (⌘,), rather than configuration buried in
/// a footer overflow menu. Everything here was already a setting before —
/// this just gives it a place a person would actually expect to find it.
public struct BoostSettingsView: View {
    @ObservedObject var engine: Engine = .shared
    @ObservedObject private var rules = Rules.shared
    @ObservedObject private var autoPause = AutoPause.shared
    @StateObject private var login = LoginItemModel()

    public init() {}

    public var body: some View {
        Form {
            Section("General") {
                Toggle("Start Boost at login", isOn: Binding(
                    get: { login.enabled },
                    set: { login.set($0) }
                ))
                if let problem = login.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Always show the percentage in the menu bar", isOn: $engine.menuBarAlways)
                    .help("Otherwise the number appears only when memory is getting busy.")
                Toggle("Close button quits the app", isOn: $engine.autoQuitOnClose)
                Toggle("Global shortcut (⌥⌘B)", isOn: $engine.globalHotkey)
                    .help("Opens Boost and closes what is ticked, from any app.")
                Toggle("Resume everything when Boost quits", isOn: $engine.resumeOnQuit)
                    .help("Nothing is ever left frozen because Boost went away.")
            }

            Section("Sleeping apps") {
                Toggle("Pause apps I leave alone", isOn: $autoPause.enabled)
                    .help("Freezes the apps listed below after they have been in the "
                        + "background for a while, and wakes each one the moment you "
                        + "switch to it. Nothing is closed.")

                if autoPause.enabled {
                    Picker("After", selection: $autoPause.idleMinutes) {
                        ForEach(AutoPause.idleChoices, id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                }

                if autoPause.listed.isEmpty {
                    Text("No apps listed. In the Memory tab, right-click an app and choose "
                        + "Auto-pause when idle. Leave out anything that plays audio or "
                        + "syncs in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(autoPause.listed.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Remove") { autoPause.remove(id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Free Memory") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Reclaim more aggressively", isOn: $engine.aggressiveReclaim)
                    Text("Pushes memory_pressure to `critical` instead of `warn`. It "
                        + "can reclaim more, and it can also be the reason the kernel "
                        + "decides to kill something on its own, with no dialog from "
                        + "Boost and no warning first. The instant-stop on swap growth "
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

                Toggle("Warn me when memory stays tight", isOn: Binding(
                    get: { rules.sustainedEnabled },
                    set: { on in
                        rules.sustainedEnabled = on
                        if on { rules.requestPermission() }
                    }
                ))
                .help("Tells you once pressure has stayed high for a minute, and which "
                    + "app is using the most. A spike that passes on its own is ignored.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
