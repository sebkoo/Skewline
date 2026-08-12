import Foundation
import Core
import Replay
import Render

/// Replays `.skewline` containers through the cross-frame reprojection
/// analysis and prints what the sensor's confidence classes actually
/// predict: per-class error scales in meters, banded by depth so range
/// cannot confound class, and their growth with frame separation -- drift.
///
/// The report is paired blocks, the RenderProbe pattern. Deterministic
/// blocks byte-reproduce across runs on one machine: fixed frame order,
/// sequential folds, fixed-format floats. The timing block is labeled
/// non-deterministic and is only meaningful from a release build. Every
/// registered constant lives in `Calibration.Constants`; the bare command
/// line is the registered analysis.
///
/// `@main` on a struct rather than top-level code in `main.swift`: top-level
/// code is `MainActor`-isolated, and nothing here wants an actor.
@main
struct CalibrationProbe {
    static let classNames = ["low", "medium", "high"]

    static func main() {
        var paths: [String] = []
        var constants = Calibration.Constants()
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        var usageError = false
        while index < arguments.count {
            switch arguments[index] {
            case "--separations":
                index += 1
                let parsed = index < arguments.count
                    ? arguments[index].split(separator: ",").compactMap { Int($0) }
                    : []
                if parsed.isEmpty || parsed.contains(where: { $0 < 1 }) {
                    usageError = true
                } else {
                    constants.separations = parsed
                }
            case "--pixel-stride":
                index += 1
                if index < arguments.count, let stride = Int(arguments[index]), stride >= 1 {
                    constants.pixelStride = stride
                } else {
                    usageError = true
                }
            default:
                paths.append(arguments[index])
            }
            index += 1
        }
        guard !paths.isEmpty, !usageError else {
            FileHandle.standardError.write(Data(
                "usage: CalibrationProbe [--separations 1,5,15,30] [--pixel-stride N] <capture.skewline> ...\n".utf8
            ))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the arithmetic's bill")
        #endif
        var failed = false
        for path in paths {
            do {
                try report(on: URL(filePath: path), constants: constants)
            } catch {
                FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
                failed = true
            }
        }
        if failed {
            exit(1)
        }
    }

    static func report(on url: URL, constants: Calibration.Constants) throws {
        let clock = ContinuousClock()
        let start = clock.now
        let report = try Calibration.analyze(
            reader: try SessionContainer.Reader(contentsOf: url),
            constants: constants
        )
        let elapsed = start.duration(to: clock.now)

        print("session \(report.sessionID.uuidString)  \(url.path)")
        let eligibility = report.eligibility
        print(row("frames", "\(eligibility.frames)"))
        print(row("eligible", "\(eligibility.eligible)"))
        let ineligible = eligibility.noDepth + eligibility.noIntrinsics + eligibility.noPose
            + eligibility.noConfidence + eligibility.anisotropicIntrinsics
        print(row(
            "ineligible",
            "\(ineligible)    no-depth \(eligibility.noDepth)"
                + " · no-intrinsics \(eligibility.noIntrinsics)"
                + " · no-pose \(eligibility.noPose)"
                + " · no-confidence \(eligibility.noConfidence)"
                + " · anisotropic-intrinsics \(eligibility.anisotropicIntrinsics)"
        ))
        print(row("median fx (depth px)", String(format: "%.2f", report.medianFocalLengthX)))
        print(row("bands (m)", bandLabels(constants.bandEdges).joined(separator: " ")))
        print(row("separations", constants.separations.map(String.init).joined(separator: " ")))
        print(row("pixel stride", "\(constants.pixelStride)"))

        for result in report.separations {
            printSeparation(result, medianFx: report.medianFocalLengthX, constants: constants)
        }
        printDriftSummary(report.separations)

        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif
        print("  --- timing (\(build); not deterministic) ---")
        print(row("analysis", String(format: "%.2f s", elapsed / .seconds(1))))
        print("")
    }

    static func printSeparation(
        _ result: Calibration.SeparationResult,
        medianFx: Float,
        constants: Calibration.Constants
    ) {
        let bands = bandLabels(constants.bandEdges)
        print("  --- k=\(result.separation) (deterministic) ---")
        print(row(
            "pairs",
            "\(result.pairsFormed) formed · \(result.pairsExcludedByDeltaT) excluded-by-dt"
        ))
        print(row("median dt (s)", String(format: "%.6f", result.medianDeltaT)))
        print(row("median baseline (m)", String(format: "%.4f", result.medianBaseline)))

        let filters = result.filters
        print(row(
            "src-depth-invalid",
            "low \(filters.sourceDepthInvalid[0]) · medium \(filters.sourceDepthInvalid[1])"
                + " · high \(filters.sourceDepthInvalid[2]) · other \(filters.sourceDepthInvalid[3])"
        ))
        print(row("src-class-out-of-domain", "\(filters.sourceClassOutOfDomain)"))
        print(row(
            "src-out-of-band",
            "low \(filters.sourceOutOfBand[0]) · medium \(filters.sourceOutOfBand[1])"
                + " · high \(filters.sourceOutOfBand[2])"
        ))
        print(row("src-edge-mask", grid(filters.sourceEdgeMask)))
        print(row("behind-camera", grid(filters.behindCamera)))
        print(row("out-of-frame", grid(filters.outOfFrame)))
        print(row("target-depth-invalid", grid(filters.targetDepthInvalid)))
        print(row("target-edge-mask", grid(filters.targetEdgeMask)))
        print(row("class-mismatch", grid(filters.classMismatch)))
        print(row("forward-backward", grid(filters.forwardBackward)))

        for band in bands.indices {
            for classIndex in classNames.indices {
                print(row(
                    "\(bands[band]) \(classNames[classIndex])",
                    stat(result.buckets[classIndex][band])
                ))
            }
            print(row("\(bands[band]) verdict", verdict(result.buckets, band: band, constants: constants)))
        }
        for classIndex in classNames.indices {
            print(row("pooled \(classNames[classIndex])", stat(result.pooled[classIndex])))
        }
        for classIndex in classNames.indices {
            print(row(
                "fwbw-off pooled \(classNames[classIndex])",
                stat(result.pooledWithoutForwardBackward[classIndex])
            ))
        }

        // The forward-backward gate is itself a depth-residual truncation:
        // a disagreement Δ moves the round trip by about fx·b·Δ/d² pixels,
        // so the radius truncates |Δ| near d²/(fx·b). The bound is printed
        // at each band's lower edge -- the tightest within the band -- and
        // a median approaching it is self-flagged.
        if result.medianBaseline > 0, medianFx > 0 {
            let fx = medianFx
            let bounds = bands.indices.map { band -> String in
                let edge = constants.bandEdges[band]
                let bound = edge * edge * constants.forwardBackwardRadius
                    / (fx * result.medianBaseline)
                return "\(bands[band]) " + String(format: "%.3f", bound)
            }
            print(row("fwbw truncation bound (m)", bounds.joined(separator: " · ")))
        } else {
            print(row("fwbw truncation bound (m)", "n/a (zero baseline)"))
        }

        if let maskOff = result.bucketsWithoutEdgeMask {
            printSensitivity("mask-off", maskOff, bands: bands, constants: constants)
        }
        if let matchOff = result.bucketsWithoutClassMatch {
            printSensitivity("match-off", matchOff, bands: bands, constants: constants)
        }
    }

    /// One line per band per lifted filter: the three class medians and the
    /// verdict they would have produced. If ordering holds only with a
    /// filter on, that is the finding, not a pass.
    static func printSensitivity(
        _ label: String,
        _ buckets: [[Calibration.BucketStat]],
        bands: [String],
        constants: Calibration.Constants
    ) {
        for band in bands.indices {
            let medians = classNames.indices.map { classIndex in
                "\(classNames[classIndex]) "
                    + String(format: "%.4f", buckets[classIndex][band].medianAbs)
            }
            print(row(
                "\(label) \(bands[band])",
                medians.joined(separator: " · ")
                    + " · verdict " + verdict(buckets, band: band, constants: constants)
            ))
        }
    }

    /// Per-class drift slopes over the pooled medians, least squares against
    /// each separation's measured median Δt -- recorded without a verdict,
    /// declared in advance: no principled threshold exists yet.
    static func printDriftSummary(_ separations: [Calibration.SeparationResult]) {
        print("  --- drift summary (deterministic) ---")
        for classIndex in classNames.indices {
            let points = separations.filter { $0.pooled[classIndex].count > 0 }.map {
                (x: $0.medianDeltaT, y: Double($0.pooled[classIndex].medianAbs))
            }
            let unfiltered = separations
                .filter { $0.pooledWithoutForwardBackward[classIndex].count > 0 }.map {
                    (x: $0.medianDeltaT, y: Double($0.pooledWithoutForwardBackward[classIndex].medianAbs))
                }
            let label = "slope \(classNames[classIndex]) (mm/s)"
            let filtered = Calibration.slope(points).map { String(format: "%+.2f", $0 * 1000) }
                ?? "n/a (fewer than two separations)"
            let lifted = Calibration.slope(unfiltered).map { String(format: "%+.2f", $0 * 1000) }
                ?? "n/a"
            print(row(label, "\(filtered) · fwbw-off \(lifted)"))
        }
    }

    static func verdict(
        _ buckets: [[Calibration.BucketStat]],
        band: Int,
        constants: Calibration.Constants
    ) -> String {
        Calibration.orderingVerdict(
            low: buckets[0][band],
            medium: buckets[1][band],
            high: buckets[2][band],
            minimumSamples: constants.minimumOrderingSamples,
            margin: constants.orderingMargin
        ).rawValue
    }

    static func stat(_ bucket: Calibration.BucketStat) -> String {
        guard bucket.count > 0 else { return "n 0" }
        return "n \(bucket.count)"
            + String(format: " · median %.4f · mad %.4f", bucket.medianAbs, bucket.mad)
            + String(format: " · signed %+.4f", bucket.medianSigned)
    }

    static func grid(_ counts: [[Int]]) -> String {
        classNames.indices.map { classIndex in
            "\(classNames[classIndex]) "
                + counts[classIndex].map(String.init).joined(separator: " ")
        }.joined(separator: " · ")
    }

    static func bandLabels(_ edges: [Float]) -> [String] {
        (1..<edges.count).map { String(format: "[%g,%g)", edges[$0 - 1], edges[$0]) }
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + value
    }
}
