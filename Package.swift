// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpatialCapture",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Replay", targets: ["Replay"]),
    ],
    targets: [
        .target(
            name: "Core"
        ),
        .target(
            name: "Replay",
            dependencies: ["Core"]
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["Core", "Replay"]
        ),
    ]
)
