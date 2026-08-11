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
        .library(name: "Render", targets: ["Render"]),
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
        .target(
            name: "Render",
            dependencies: ["Core", "Replay"]
        ),
        .executableTarget(
            name: "RenderProbe",
            dependencies: ["Core", "Replay", "Render"]
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["Core", "Replay", "Capture", "Render"]
        ),
    ]
)
