import Foundation
import simd
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Core
import Replay
import Render

/// Replays `.skewline` containers through decode and unprojection and prints
/// what that cost -- the numbers that either force the render rung's Metal
/// kernel or embarrass the roadmap's claim that one is needed -- then puts
/// the accumulated cloud on the GPU and measures what the GPU delivers
/// against the bill the CPU blocks present.
///
/// The report is paired blocks. Deterministic blocks hold counts, tallies and
/// bounds that must reproduce byte-for-byte across runs on one machine,
/// because frame order is fixed and every fold is sequential -- the GPU's
/// deterministic block stays integer-only for the same reason. Timing blocks
/// are labeled as non-deterministic, and the CPU one is only meaningful from
/// a release build.
///
/// `@main` on a struct rather than top-level code in `main.swift`: top-level
/// code is `MainActor`-isolated, and nothing here wants an actor.
@main
struct RenderProbe {
    static func main() {
        var paths: [String] = []
        var pngDirectory: URL?
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        var usageError = false
        while index < arguments.count {
            if arguments[index] == "--png" {
                index += 1
                if index < arguments.count {
                    pngDirectory = URL(filePath: arguments[index], directoryHint: .isDirectory)
                } else {
                    usageError = true
                }
            } else {
                paths.append(arguments[index])
            }
            index += 1
        }
        guard !paths.isEmpty, !usageError else {
            FileHandle.standardError.write(Data("usage: RenderProbe [--png <dir>] <capture.skewline> ...\n".utf8))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the arithmetic's bill")
        #endif
        var failed = false
        for path in paths {
            do {
                try report(on: URL(filePath: path), pngDirectory: pngDirectory)
            } catch {
                FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
                failed = true
            }
        }
        if failed {
            exit(1)
        }
    }

    enum ProbeError: Error {
        /// The kernel's color tally disagreed with the CPU confidence tally
        /// mapped through the palette -- a broken kernel, not a skip.
        case colorTallyMismatch

        /// CoreGraphics or ImageIO declined to build or write the image.
        case pngEncodingFailed
    }

    /// The frame the offscreen render looks through: the median-index frame
    /// among the frames that reached unprojection -- deterministic, and the
    /// sweep's midpoint is the pose most likely to face the scene it half
    /// built. Nothing about the camera is invented; every operand is the
    /// container's.
    struct Viewpoint {
        let index: Int
        let timestamp: TimeInterval
        let intrinsics: IntrinsicsRecord
        let pose: Transform4x4
    }

    static func report(on url: URL, pngDirectory: URL?) throws {
        let reader = try SessionContainer.Reader(contentsOf: url)
        let session = reader.session

        /// Frame timestamps are members of the pose set on every observed
        /// capture, so association is an exact-match lookup -- a miss is
        /// counted, never bridged to the nearest neighbour.
        let poseByTimestamp = Dictionary(
            session.observations.map { ($0.timestamp, $0.transform) },
            uniquingKeysWith: { first, _ in first }
        )

        // Eligibility from metadata alone -- the frames the loop below will
        // unproject, and the upper bound on their sample count -- so the
        // cloud buffer is allocated once, before any payload is read, and
        // every frame's points are appended straight into unified memory.
        // The 2.43 GB cloud exists exactly once.
        var eligible: [Viewpoint] = []
        var cloudCapacity = 0
        for (index, frame) in session.frames.enumerated() {
            guard let depthRecord = frame.depth, depthRecord.confidence != nil,
                  let intrinsics = frame.intrinsics,
                  let pose = poseByTimestamp[frame.timestamp] else { continue }
            eligible.append(Viewpoint(
                index: index, timestamp: frame.timestamp, intrinsics: intrinsics, pose: pose
            ))
            cloudCapacity += depthRecord.width * depthRecord.height
        }

        let device = MTLCreateSystemDefaultDevice()
        var cloud: AccumulatedCloudBuffer?
        var cloudAllocationFailureBytes: Int?
        if let device, cloudCapacity > 0 {
            do {
                cloud = try AccumulatedCloudBuffer(device: device, capacity: cloudCapacity)
            } catch RenderGPUError.bufferAllocationFailed(let bytes) {
                cloudAllocationFailureBytes = bytes
            }
        }

        var framesWithDepth = 0
        var noDepth = 0
        var noIntrinsics = 0
        var noPose = 0
        var noConfidence = 0
        var pointCount = 0
        var skippedInvalidDepth = 0
        var confidenceCounts = [Int](repeating: 0, count: 256)
        var depthRange: ClosedRange<Float>?
        var worldMin = SIMD3<Float>(repeating: .infinity)
        var worldMax = SIMD3<Float>(repeating: -.infinity)
        var frameMilliseconds: [Double] = []
        var clockedSeconds = 0.0

        let clock = ContinuousClock()
        for (index, frame) in session.frames.enumerated() {
            try autoreleasepool {
                guard let depthRecord = frame.depth else {
                    noDepth += 1
                    return
                }
                framesWithDepth += 1
                // Read the payload for every frame that has one, whether or
                // not it can be unprojected: a container whose bytes cannot
                // be read should fail this probe loudly, not pass it by
                // being unprojectable for a different reason.
                let depthData = try reader.depthData(at: index)
                let confidenceData = depthRecord.confidence != nil
                    ? try reader.confidenceData(at: index)
                    : nil
                guard let intrinsics = frame.intrinsics else {
                    noIntrinsics += 1
                    return
                }
                guard let pose = poseByTimestamp[frame.timestamp] else {
                    noPose += 1
                    return
                }
                guard confidenceData != nil else {
                    noConfidence += 1
                    return
                }

                let start = clock.now
                let decoded = try DepthDecoder.decode(
                    record: depthRecord,
                    depthData: depthData,
                    confidenceData: confidenceData
                )
                let result = try Unprojector.unproject(
                    depth: decoded,
                    intrinsics: intrinsics,
                    cameraToWorld: pose
                )
                let elapsed = start.duration(to: clock.now)

                let milliseconds = elapsed / .milliseconds(1)
                frameMilliseconds.append(milliseconds)
                clockedSeconds += milliseconds / 1000

                pointCount += result.points.count
                skippedInvalidDepth += result.skippedInvalidDepth
                cloud?.append(result.points)
                for point in result.points {
                    confidenceCounts[Int(point.confidence)] += 1
                    worldMin = simd_min(worldMin, point.position)
                    worldMax = simd_max(worldMax, point.position)
                }
                for sample in decoded.depths where sample > 0 && sample.isFinite {
                    if let range = depthRange {
                        depthRange = min(range.lowerBound, sample)...max(range.upperBound, sample)
                    } else {
                        depthRange = sample...sample
                    }
                }
            }
        }

        let unprojectable = noDepth + noIntrinsics + noPose + noConfidence
        print("session \(session.id.uuidString)  \(url.path)")
        print(row("frames", "\(session.frames.count)"))
        print(row("frames with depth", "\(framesWithDepth)"))
        print(row(
            "unprojectable",
            "\(unprojectable)    no-depth \(noDepth) · no-intrinsics \(noIntrinsics)"
                + " · no-pose \(noPose) · no-confidence \(noConfidence)"
        ))
        print(row("points", "\(pointCount)"))
        print(row("invalid depth samples", "\(skippedInvalidDepth)"))
        let other = confidenceCounts.indices.dropFirst(3).filter { confidenceCounts[$0] > 0 }
        let otherTotal = other.reduce(0) { $0 + confidenceCounts[$1] }
        print(row(
            "confidence",
            "low \(confidenceCounts[0]) · medium \(confidenceCounts[1]) · high \(confidenceCounts[2])"
                + " · other \(otherTotal)\(other.isEmpty ? "" : " \(other)")"
        ))
        if let depthRange {
            print(row(
                "depth range (m)",
                String(format: "%.3f – %.3f", depthRange.lowerBound, depthRange.upperBound)
            ))
            print(row(
                "world bounds (m)",
                String(
                    format: "x [%.3f, %.3f] · y [%.3f, %.3f] · z [%.3f, %.3f]",
                    worldMin.x, worldMax.x, worldMin.y, worldMax.y, worldMin.z, worldMax.z
                )
            ))
        }
        let stride = MemoryLayout<ConfidencePoint>.stride
        print(row(
            "full-cloud memory",
            String(
                format: "%d points × %d B (MemoryLayout stride) = %.2f GB",
                pointCount, stride, Double(pointCount * stride) / 1_000_000_000
            )
        ))

        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif
        print("  --- timing (\(build); not deterministic) ---")
        if frameMilliseconds.isEmpty {
            print(row("decode + unproject", "no frames reached the arithmetic"))
            try gpuReport(
                url: url, device: device, cloud: cloud,
                allocationFailureBytes: cloudAllocationFailureBytes,
                eligible: eligible, confidenceCounts: confidenceCounts,
                depthRange: depthRange, worldMin: worldMin, worldMax: worldMax,
                pngDirectory: pngDirectory
            )
            print("")
            return
        }
        let sorted = frameMilliseconds.sorted()
        let median = sorted[sorted.count / 2]
        print(row(
            "decode + unproject",
            String(
                format: "total %.2f s · per-frame ms %.2f/%.2f/%.2f min/median/max · %.1f M points/s",
                clockedSeconds, sorted.first ?? 0, median, sorted.last ?? 0,
                Double(pointCount) / clockedSeconds / 1_000_000
            )
        ))
        print(row(
            "re-shade bill at 60 Hz",
            String(
                format: "%d points × 60 = %.2f G points/s against measured %.1f M points/s",
                pointCount, Double(pointCount) * 60 / 1_000_000_000,
                Double(pointCount) / clockedSeconds / 1_000_000
            )
        ))
        try gpuReport(
            url: url, device: device, cloud: cloud,
            allocationFailureBytes: cloudAllocationFailureBytes,
            eligible: eligible, confidenceCounts: confidenceCounts,
            depthRange: depthRange, worldMin: worldMin, worldMax: worldMax,
            pngDirectory: pngDirectory
        )
        print("")
    }

    /// The GPU phase: both re-shade kernels and both full-cloud renders over
    /// both layouts, against the bill the CPU block presents. The
    /// deterministic block stays integer-only -- counts and bytes a GPU
    /// cannot wobble; every clock reading stays in the timing block.
    static func gpuReport(
        url: URL,
        device: MTLDevice?,
        cloud: AccumulatedCloudBuffer?,
        allocationFailureBytes: Int?,
        eligible: [Viewpoint],
        confidenceCounts: [Int],
        depthRange: ClosedRange<Float>?,
        worldMin: SIMD3<Float>,
        worldMax: SIMD3<Float>,
        pngDirectory: URL?
    ) throws {
        print("  --- gpu (deterministic) ---")
        guard let device else {
            print(row("gpu", "no Metal device -- skipped"))
            return
        }
        if let bytes = allocationFailureBytes {
            print(row("gpu", "cloud allocation refused (\(bytes) B) -- skipped"))
            return
        }
        guard let cloud, cloud.count > 0, let depthRange, !eligible.isEmpty else {
            print(row("gpu", "no points -- skipped"))
            return
        }
        let count = cloud.count
        let viewpoint = eligible[eligible.count / 2]

        print(row("device", "\(device.name) · maxBufferLength \(device.maxBufferLength) B"))
        print(row("layout aos32", "\(count) × 32 B = \(count * 32) B"))
        print(row("layout soa", "\(count) × (12 B + 1 B) = \(count * 13) B"))

        let library = try ShaderLibrary.makeLibrary(device: device)
        guard let queue = device.makeCommandQueue() else {
            throw RenderGPUError.commandBufferFailed("could not create a command queue")
        }
        let soa = try cloud.makeSoA(device: device)
        let pass = try ReshadePass(device: device, library: library)
        let colors = try pass.makeColorBuffer(count: count)

        // One dispatch, read back, tally on the CPU -- integer lookups end
        // to end, so this is deterministic, and it must equal the confidence
        // tally mapped through the palette or the kernel is wrong.
        _ = try pass.reshade(source: cloud.aos32, layout: .aos32, count: count, into: colors, queue: queue)
        let shaded = colors.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: count)
        var low = 0, medium = 0, high = 0, outOfDomain = 0, unexpected = 0
        for index in 0..<count {
            switch shaded[index] {
            case ConfidencePalette.low: low += 1
            case ConfidencePalette.medium: medium += 1
            case ConfidencePalette.high: high += 1
            case ConfidencePalette.outOfDomain: outOfDomain += 1
            default: unexpected += 1
            }
        }
        print(row(
            "color tally",
            "low \(low) · medium \(medium) · high \(high) · out-of-domain \(outOfDomain)"
        ))
        let expectedOutOfDomain = confidenceCounts.indices.dropFirst(3)
            .reduce(0) { $0 + confidenceCounts[$1] }
        let matches = unexpected == 0
            && low == confidenceCounts[0] && medium == confidenceCounts[1]
            && high == confidenceCounts[2] && outOfDomain == expectedOutOfDomain
        print(row("matches confidence tally", matches ? "yes" : "MISMATCH"))
        guard matches else {
            throw ProbeError.colorTallyMismatch
        }

        print(row(
            "viewpoint",
            String(format: "frame %d · t %.6f", viewpoint.index, viewpoint.timestamp)
        ))
        let near = max(0.01, depthRange.lowerBound)
        let pose = viewpoint.pose.simd
        let cameraPosition = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let center = (worldMin + worldMax) / 2
        let far = max(
            near + 1,
            simd_distance(cameraPosition, center) + simd_length(worldMax - worldMin) / 2
        )
        print(row("near / far (m)", String(format: "%.3f / %.3f", near, far)))

        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif
        print("  --- gpu timing (\(build); not deterministic) ---")
        let warmIterations = 20
        for layout in PointCloudLayout.allCases {
            let source = layout == .aos32 ? cloud.aos32 : soa.confidences
            var timings: [GPUTiming] = []
            for _ in 0...warmIterations {
                timings.append(try pass.reshade(
                    source: source, layout: layout, count: count, into: colors, queue: queue
                ))
            }
            print(row("reshade \(layout.rawValue)", timingSummary(timings, count: count)))
        }

        let renderer = try PointCloudRenderer(
            device: device,
            library: library,
            width: viewpoint.intrinsics.referenceWidth,
            height: viewpoint.intrinsics.referenceHeight
        )
        let viewProjection = PinholeProjection.projectionMatrix(
            intrinsics: viewpoint.intrinsics, near: near, far: far
        ) * PinholeProjection.viewMatrix(cameraToWorld: viewpoint.pose)
        for layout in PointCloudLayout.allCases {
            var timings: [GPUTiming] = []
            for _ in 0...warmIterations {
                timings.append(try renderer.render(
                    positions: layout == .aos32 ? cloud.aos32 : soa.positions,
                    confidences: layout == .soa ? soa.confidences : nil,
                    layout: layout,
                    count: count,
                    viewProjection: viewProjection,
                    pointSize: 1,
                    queue: queue
                ))
            }
            print(row("render \(layout.rawValue)", timingSummary(timings, count: count)))
        }

        if let pngDirectory {
            let destination = pngDirectory.appending(
                path: url.deletingPathExtension().lastPathComponent + "-cloud.png"
            )
            try writePNG(
                pixels: renderer.readbackRGBA(),
                width: renderer.width,
                height: renderer.height,
                to: destination
            )
            print(row("image", destination.path))
        }
    }

    /// Cold first iteration on its own -- the in-run analogue of the CPU
    /// probe's cold/warm story -- then min/median/max and rates over the
    /// warm rest: the wall clock around commit-and-wait, and the device's
    /// own interval when it reports one.
    private static func timingSummary(_ timings: [GPUTiming], count: Int) -> String {
        let coldMs = timings[0].wallSeconds * 1000
        let warm = Array(timings.dropFirst())
        let wallMs = warm.map { $0.wallSeconds * 1000 }.sorted()
        let wallTotal = warm.reduce(0.0) { $0 + $1.wallSeconds }
        let wallRate = Double(count) * Double(warm.count) / wallTotal / 1_000_000_000
        let gpuSeconds = warm.compactMap(\.gpuSeconds)
        let gpuLabel: String
        if gpuSeconds.count == warm.count {
            let gpuRate = Double(count) * Double(warm.count) / gpuSeconds.reduce(0, +) / 1_000_000_000
            gpuLabel = String(format: "%.2f G points/s gpu-clock", gpuRate)
        } else {
            gpuLabel = "gpu interval unavailable"
        }
        return String(
            format: "cold %.2f ms · warm ms %.2f/%.2f/%.2f min/median/max (%d iters) · %.2f G points/s wall · %@",
            coldMs, wallMs.first ?? 0, wallMs[wallMs.count / 2], wallMs.last ?? 0,
            warm.count, wallRate, gpuLabel
        )
    }

    /// The reviewable artifact: the rendered target as a PNG. Lives in the
    /// probe because encoding an image is the report's concern, not the
    /// renderer's.
    private static func writePNG(pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else {
            throw ProbeError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProbeError.pngEncodingFailed
        }
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + value
    }
}
