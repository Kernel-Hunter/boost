import SwiftUI

@main
struct BoostApp: App {
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
    }
}
