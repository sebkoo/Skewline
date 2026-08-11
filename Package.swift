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
            dependencies: ["Core", "Replay"],
            // The shader ships as source, compiled at runtime. `.msl`, not
            // `.metal`: xcodebuild claims a `.metal` file for its Metal
            // compiler even when it is declared `.copy` -- and Xcode 26's
            // Metal toolchain is a separate download -- while `swift build`
            // only ever copies it. One extension no build system claims is
            // what keeps the bundle identical under both.
            resources: [.copy("Shaders/ConfidenceShaders.msl")]
        ),
        .executableTarget(
            name: "RenderProbe",
            dependencies: ["Core", "Replay", "Render"]
        ),
        .executableTarget(
            name: "StorageProbe",
            dependencies: ["Core", "Replay", "Capture"]
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["Core", "Replay", "Capture", "Render"]
        ),
    ]
)
