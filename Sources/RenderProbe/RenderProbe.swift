import Foundation
import simd
import Core
import Replay
import Render

/// Replays `.skewline` containers through decode and unprojection and prints
/// what that cost -- the numbers that either force the render rung's Metal
/// kernel or embarrass the roadmap's claim that one is needed.
///
/// The report is two blocks. The first is deterministic: counts, tallies and
/// bounds that must reproduce byte-for-byte across runs on one machine,
/// because frame order is fixed and every fold is sequential. The second is
/// timing, labeled as non-deterministic, and only meaningful from a release
/// build.
///
/// `@main` on a struct rather than top-level code in `main.swift`: top-level
/// code is `MainActor`-isolated, and nothing here wants an actor.
@main
struct RenderProbe {
    static func main() {
        let paths = CommandLine.arguments.dropFirst()
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data("usage: RenderProbe <capture.skewline> ...\n".utf8))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the arithmetic's bill")
        #endif
        var failed = false
        for path in paths {
            do {
                try report(on: URL(filePath: path))
            } catch {
                FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
                failed = true
            }
        }
        if failed {
            exit(1)
        }
    }

    static func report(on url: URL) throws {
        let reader = try SessionContainer.Reader(contentsOf: url)
        let session = reader.session

        /// Frame timestamps are members of the pose set on every observed
        /// capture, so association is an exact-match lookup -- a miss is
        /// counted, never bridged to the nearest neighbour.
        let poseByTimestamp = Dictionary(
            session.observations.map { ($0.timestamp, $0.transform) },
            uniquingKeysWith: { first, _ in first }
        )

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
        print("")
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + value
    }
}
