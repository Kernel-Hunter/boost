import SwiftUI
import BoostKit

@main
struct BoostApp: App {
    @ObservedObject private var engine = Engine.shared

    var body: some Scene {
        WindowGroup("Boost") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Engine.shared.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Resume Everything") { Engine.shared.resumeEverything() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // Memory pressure is worth knowing before you go looking for it, and the
        // moment you want this app is the moment the Mac is too slow to go
        // hunting for its window.
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel(engine: engine)
        }
    }
}
