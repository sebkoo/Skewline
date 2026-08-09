// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Skewline",
    platforms: [
        .iOS(.v18),
        .macOS(.v13),
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Replay", targets: ["Replay"]),
        .library(name: "Capture", targets: ["Capture"]),
    ],
    targets: [
        .target(
            name: "Core"
        ),
        .target(
            name: "Replay",
            dependencies: ["Core"]
        ),
        .target(
            name: "Capture",
            dependencies: ["Core", "Replay"]
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["Core", "Replay", "Capture"]
        ),
    ]
)
