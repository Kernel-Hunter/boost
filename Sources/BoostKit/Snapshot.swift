import SwiftUI
import AppKit

/// Renders views to PNG files and exits: `Boost --snapshot <directory>`.
///
/// Each view is hosted in a real, offscreen AppKit window and drawn from there,
/// so lists, buttons and materials come out as they do on screen. Screenshots
/// for the README should be made this way, from the real views with real data,
/// rather than from a mockup.
public enum Snapshot {

    public static func requestedDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    @MainActor
    public static func run(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // Screenshots show the app as it looks once the welcome card is gone.
        UserDefaults.standard.set(true, forKey: "firstRunDismissed")
        UserDefaults.standard.set(30, forKey: "projectCutoffDays")

        let engine = Engine.shared
        for _ in 0..<4 { engine.refresh() }

        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let label = scheme == .dark ? "dark" : "light"
            write(MenuBarContent(), size: nil, name: "popover-\(label)", scheme: scheme, settle: 0.5, to: directory)

            write(BoostSettingsView(), size: CGSize(width: 460, height: 760),
                  name: "settings-\(label)", scheme: scheme, settle: 0.5, to: directory)

            for tab in Tab.allCases {
                UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
                write(ContentView(), size: CGSize(width: 1040, height: 760),
                      name: "\(tab.rawValue)-\(label)", scheme: scheme,
                      settle: tab == .memory ? 3.0 : 12.0, to: directory)
            }
        }
        exit(0)
    }

    @MainActor
    private static func write<V: View>(_ view: V, size: CGSize?, name: String, scheme: ColorScheme,
                                       settle: TimeInterval, to directory: URL) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme))
        host.appearance = appearance
        let finalSize = size ?? host.fittingSize
        let frame = NSRect(origin: .zero, size: finalSize)

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = NSColor.windowBackgroundColor
        host.frame = frame
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()

        // Give SwiftUI and the engines a few turns of the run loop to fill in.
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("snapshot failed: \(name)\n".utf8))
            return
        }
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
