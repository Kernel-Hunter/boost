import SwiftUI
import AppKit

/// Renders views to PNG files and exits: `Boost --snapshot <directory>`.
///
/// There is no other reliable way to look at a menu bar popover from a script,
/// and screenshots for the README should come from the real views with real
/// data rather than from a mockup.
public enum Snapshot {

    public static func requestedDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    @MainActor
    public static func run(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = Engine.shared
        for _ in 0..<4 { engine.refresh() }

        for (scheme, label) in [(ColorScheme.dark, "dark"), (ColorScheme.light, "light")] {
            write(MenuBarContent(), name: "popover-\(label)", scheme: scheme, to: directory)
        }

        // Layout check only: a made-up day, never used for screenshots that
        // claim to show a real Mac.
        var demo = LongHistory()
        let now = Date()
        for m in 0..<(24 * 60) {
            let t = Double(m) / 60
            let wave = 0.55 + 0.18 * sin(t / 2.2) + (m % 233 < 14 ? 0.22 : 0)
            demo.record(at: now.addingTimeInterval(Double(m - 24 * 60) * 60),
                        pressure: min(0.98, wave), swapBytes: m % 233 < 14 ? 1_500_000_000 : 0)
        }
        for (scheme, label) in [(ColorScheme.dark, "dark"), (ColorScheme.light, "light")] {
            write(HistoryCard(history: demo).frame(width: 760), name: "history-\(label)", scheme: scheme, to: directory)
        }
        exit(0)
    }

    @MainActor
    private static func write<V: View>(_ view: V, name: String, scheme: ColorScheme, to directory: URL) {
        // Materials render as nothing outside a window, so the surface is
        // painted explicitly to match what the popover sits on.
        let framed = view
            .background(Color(nsColor: scheme == .dark
                              ? NSColor(white: 0.16, alpha: 1)
                              : NSColor(white: 0.96, alpha: 1)))
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed: \(name)\n".utf8))
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
