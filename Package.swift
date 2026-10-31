// swift-tools-version: 6.0
import PackageDescription

// Two targets on purpose: everything worth testing lives in BoostKit, and the
// `boost` executable is a thin @main shell around it. Scripts/build.sh wraps
// that executable into Boost.app. Builds and tests with Command Line Tools
// alone — no Xcode required.
let package = Package(
    name: "Boost",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. Pinned to an exact version rather than a range: this
        // code replaces the app on people's machines, so a new Sparkle should
        // arrive as a deliberate bump someone read the changelog for, not as a
        // side effect of resolving packages.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "BoostKit", dependencies: [
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .executableTarget(
            name: "boost",
            dependencies: ["BoostKit"],
            // Sparkle ships as a framework, not a static library, so the binary
            // has to be able to find it once build.sh copies it into
            // Contents/Frameworks. SwiftPM only adds rpaths for its own build
            // folder, which does not exist on anyone else's Mac.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "BoostKitTests", dependencies: ["BoostKit"]),
    ]
)
