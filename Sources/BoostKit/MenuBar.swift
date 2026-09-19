import SwiftUI
import AppKit

/// The menu bar readout and its menu.
///
/// The point of a utility like this is that you reach for it when the Mac
/// already feels slow — which is the worst moment to be hunting for a window.
/// Pressure lives in the menu bar, and the two actions worth having are one
/// press away.
public struct MenuBarLabel: View {
    @ObservedObject var engine: Engine

    public init(engine: Engine = .shared) { self.engine = engine }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
            // The number appears only when it is worth reading. A menu bar is
            // finite — on a notched Mac with a few other items it is very
            // finite — and a figure that is always there is one you stop
            // seeing, which is the opposite of the point. Percentage rather
            // than gigabytes: "68%" means something on its own, "10.9 GB"
            // only means something if you remember the size of your Mac.
            if showsNumber {
                Text("\(Int(engine.mem.pressure * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(tint)
        .accessibilityLabel("Memory \(Int(engine.mem.pressure * 100)) percent used"
            + (engine.pausedItems.isEmpty ? "" : ", \(engine.pausedItems.count) paused"))
    }

    private var showsNumber: Bool {
        engine.mem.level != .easy || !engine.pausedItems.isEmpty
    }

    private var symbol: String {
        engine.pausedItems.isEmpty ? "memorychip" : "pause.circle.fill"
    }

    /// Only coloured when it means something. A menu bar item that is always
    /// orange is one you stop reading.
    private var tint: Color {
        if !engine.pausedItems.isEmpty { return .orange }
        switch engine.mem.level {
        case .easy:     return .primary
        case .moderate: return .primary
        case .tight:    return .red
        }
    }
}

public struct MenuBarContent: View {
    @ObservedObject var engine: Engine
    @ObservedObject var disk: DiskEngine

    public init(engine: Engine = .shared, disk: DiskEngine = .shared) {
        self.engine = engine
        self.disk = disk
    }

    public var body: some View {
        // Read-only summary first: most openings of this menu are a question,
        // not an instruction.
        Text("\(fmtBytes(engine.mem.used)) of \(fmtBytes(engine.mem.total)) in use")
        Text(engine.mem.swapUsed == 0
             ? "No swap: your Mac is coping"
             : "\(fmtBytes(engine.mem.swapUsed)) swap: this is the number that matters")

        Divider()

        Button("Free memory") { engine.freeMemory() }
            .disabled(engine.busy != nil)

        Divider()

        Button("Close selected apps (\(engine.selectedItems.count))") {
            engine.quitSelected()
        }
        .disabled(engine.selectedItems.isEmpty || engine.busy != nil)

        Button("Pause \(engine.selectedItems.count) (reversible)") {
            engine.pauseSelected()
        }
        .disabled(engine.selectedItems.isEmpty)

        if !engine.pausedItems.isEmpty {
            Button("Resume All (\(engine.pausedItems.count))") { engine.resumeEverything() }
        }

        Divider()

        Button("Open Boost") { NSApp.activate(ignoringOtherApps: true); openMainWindow() }
        Button("Quit Boost") { NSApp.terminate(nil) }
    }

    /// The window is closed, not destroyed, when you click its red button, so
    /// bringing it back means finding it rather than making another.
    private func openMainWindow() {
        if let existing = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
            existing.makeKeyAndOrderFront(nil)
        }
    }
}
