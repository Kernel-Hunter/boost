// swift-tools-version: 6.0
import PackageDescription

// Two targets on purpose: everything worth testing lives in BoostKit, and the
// `boost` executable is a thin @main shell around it. Scripts/build.sh wraps
// that executable into Boost.app. Builds and tests with Command Line Tools
// alone — no Xcode required.
let package = Package(
    name: "Boost",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BoostKit"),
        .executableTarget(name: "boost", dependencies: ["BoostKit"]),
        .testTarget(name: "BoostKitTests", dependencies: ["BoostKit"]),
    ]
)
