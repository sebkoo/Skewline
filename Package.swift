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
        .library(name: "Interop", targets: ["Interop"]),
        .library(name: "Model", targets: ["Model"]),
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
        // The PLY parser, C++ behind a pure C header. The C interface is
        // the seam decision: a Swift target built with C++ interoperability
        // forces `.interoperabilityMode(.Cxx)` onto every importer -- the
        // tests, the probes, every later rung -- because an importer
        // rebuilds this target's clang module in its own language mode.
        // Keeping the header C keeps the C++ a private fact of this target,
        // which is why no target below carries `swiftSettings`.
        .target(
            name: "PLY"
        ),
        .target(
            name: "Interop",
            dependencies: ["PLY"]
        ),
        // The fitted model, read from the service that serves it. Depends on
        // nothing above: it owns its value types and never reaches for
        // Render's points, because joining a model to rendered points is the
        // consumer's edge rather than this module's.
        .target(
            name: "Model"
        ),
        .executableTarget(
            name: "RenderProbe",
            dependencies: ["Core", "Replay", "Render"]
        ),
        .executableTarget(
            name: "StorageProbe",
            dependencies: ["Core", "Replay", "Capture"]
        ),
        .executableTarget(
            name: "CalibrationProbe",
            dependencies: ["Core", "Replay", "Render"]
        ),
        .executableTarget(
            name: "InteropProbe",
            dependencies: ["Core", "Replay", "Render", "Interop"]
        ),
        .executableTarget(
            name: "ModelProbe",
            dependencies: ["Model"]
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["Core", "Replay", "Capture", "Render", "Interop", "Model"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
