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
        var dumpPath: String?
        var decimation = 64
        var geometryPath: String?
        // Registered default. It must exceed the largest separation exported
        // -- at P <= k two kept pairs share a frame -- and 8 is 0.27 s apart
        // at 30 fps, a visibly different viewpoint for a hand-held sensor
        // rather than merely a non-shared frame.
        var pairStride = 8
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
            case "--dump-observations":
                index += 1
                if index < arguments.count {
                    dumpPath = arguments[index]
                } else {
                    usageError = true
                }
            case "--observation-decimation":
                index += 1
                if index < arguments.count, let parsed = Int(arguments[index]), parsed >= 1 {
                    decimation = parsed
                } else {
                    usageError = true
                }
            case "--dump-geometry":
                index += 1
                if index < arguments.count {
                    geometryPath = arguments[index]
                } else {
                    usageError = true
                }
            case "--pair-stride":
                index += 1
                if index < arguments.count, let parsed = Int(arguments[index]), parsed >= 1 {
                    pairStride = parsed
                } else {
                    usageError = true
                }
            default:
                paths.append(arguments[index])
            }
            index += 1
        }
        // A dump binds one provenance header to one session: two containers
        // through one file would interleave sessions silently.
        if dumpPath != nil, paths.count != 1 {
            usageError = true
        }
        if geometryPath != nil, paths.count != 1 {
            usageError = true
        }
        // Two schemas through one analysis would give two files whose
        // sampling rules disagree while their headers both claim this run.
        if dumpPath != nil, geometryPath != nil {
            usageError = true
        }
        // The independence the permuted null rests on: at P <= k two kept
        // pairs share a frame, so a partner from "a different pair" would
        // still share a camera, a pose error and a depth map.
        if geometryPath != nil, let widest = constants.separations.max(), widest >= pairStride {
            usageError = true
        }
        guard !paths.isEmpty, !usageError else {
            let usage = "usage: CalibrationProbe [--separations 1,5,15,30] [--pixel-stride N]"
                + " [--dump-observations <out.csv> [--observation-decimation N]]"
                + " [--dump-geometry <out.csv> [--pair-stride P]]"
                + " <capture.skewline> ...\n"
                + "       --dump-observations and --dump-geometry each require exactly one\n"
                + "       container, and cannot be combined\n"
                + "       --pair-stride must exceed the largest --separations value\n"
            FileHandle.standardError.write(Data(usage.utf8))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the arithmetic's bill")
        #endif
        var failed = false
        for path in paths {
            do {
                try report(
                    on: URL(filePath: path),
                    constants: constants,
                    dump: dumpPath.map { (output: URL(filePath: $0), decimation: decimation) },
                    geometry: geometryPath.map {
                        (output: URL(filePath: $0), pairStride: pairStride)
                    }
                )
            } catch {
                FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
                failed = true
            }
        }
        if failed {
            exit(1)
        }
    }

    static func report(
        on url: URL,
        constants: Calibration.Constants,
        dump: (output: URL, decimation: Int)? = nil,
        geometry: (output: URL, pairStride: Int)? = nil
    ) throws {
        let collector = dump.map { ObservationCollector(decimation: $0.decimation) }
        let geometryCollector = geometry.map { GeometryCollector(pairStride: $0.pairStride) }
        let clock = ContinuousClock()
        let start = clock.now
        let sink: ((Calibration.Observation) -> Void)?
        switch (collector, geometryCollector) {
        case (let c?, nil): sink = { c.consume($0) }
        case (nil, let g?): sink = { g.consume($0) }
        default: sink = nil
        }
        let report = try Calibration.analyze(
            reader: try SessionContainer.Reader(contentsOf: url),
            constants: constants,
            observationSink: sink
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

        if let dump, let collector {
            try writeObservations(
                collector,
                to: dump.output,
                sessionID: report.sessionID,
                constants: constants
            )
        }
        if let geometry, let geometryCollector {
            try writeGeometry(
                geometryCollector,
                to: geometry.output,
                sessionID: report.sessionID,
                constants: constants
            )
        }

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

    /// The fit's data seam, probe-side: decimates the sink's stream and keeps
    /// the pre-decimation survivor counts a decimated file cannot recover.
    /// Registered phase: one counter per (k × class × band), starting at
    /// zero, keep when `counter % N == 0` -- systematic-every-Nth over the
    /// analysis's deterministic accumulation order, no randomness.
    final class ObservationCollector {
        var sampler: Calibration.EveryNthSampler
        var rows: [String] = []

        var decimation: Int { sampler.interval }
        var survivors: [Calibration.ObservationBucket: Int] { sampler.survivors }

        init(decimation: Int) {
            self.sampler = Calibration.EveryNthSampler(interval: decimation)
        }

        func consume(_ observation: Calibration.Observation) {
            guard sampler.keep(observation) else { return }
            // Shortest-round-trip `description` for every float: lossless,
            // deterministic and locale-independent, where a fixed decimal
            // format would drop low bits of near samples for nothing.
            rows.append(
                "\(observation.separation),\(observation.deltaT),"
                    + "\(observation.confidenceClass),\(observation.depth),\(observation.residual)"
            )
        }
    }

    /// The span analysis's seam, probe-side. Same shape as the collector
    /// above and a different retention rule: whole frame pairs rather than
    /// every Nth survivor, because separation is a within-pair quantity.
    ///
    /// The intrinsics table is filled from the observations this collector
    /// actually keeps, so the header is a projection of the rows beneath it
    /// rather than a second path that could disagree with them.
    final class GeometryCollector {
        var sampler: Calibration.PairStrideSampler
        var rows: [String] = []
        var intrinsics: [Int: ScaledIntrinsics] = [:]

        var pairStride: Int { sampler.stride }
        var survivors: [Calibration.ObservationBucket: Int] { sampler.survivors }

        init(pairStride: Int) {
            self.sampler = Calibration.PairStrideSampler(stride: pairStride)
        }

        func consume(_ observation: Calibration.Observation) {
            guard sampler.keep(observation) else { return }
            intrinsics[observation.sourceFrame] = observation.sourceIntrinsics
            rows.append(
                "\(observation.separation),\(observation.deltaT),"
                    + "\(observation.confidenceClass),\(observation.depth),"
                    + "\(observation.residual),"
                    + "\(observation.sourceFrame),\(observation.targetFrame),"
                    + "\(observation.sourceX),\(observation.sourceY),"
                    + "\(observation.targetX),\(observation.targetY),"
                    + "\(observation.roundTripX),\(observation.roundTripY)"
            )
        }
    }

    static let geometryColumns = "k,delta_t,class,depth,delta,src_frame,tgt_frame"
        + ",src_x,src_y,tgt_x,tgt_y,rt_dx,rt_dy"

    /// The `/2` file. Everything the `/1` header carries, in the same order,
    /// then the pair-level sampling provenance, then one `# intrinsics` line
    /// per exported source frame.
    ///
    /// **This file is not shippable.** Its rows carry a frame index and a
    /// pixel, so grouped by frame they are a subsampled depth image of
    /// whatever the sensor was pointed at. It stays beside the container it
    /// came from; only aggregates ever enter the repository, and the drift
    /// check refuses a committed one by its schema tag.
    static func writeGeometry(
        _ collector: GeometryCollector,
        to output: URL,
        sessionID: UUID,
        constants: Calibration.Constants
    ) throws {
        var lines: [String] = [
            "# skewline-observations/2",
            "# session \(sessionID.uuidString)",
            "# separations \(constants.separations.map(String.init).joined(separator: ","))",
            "# nominal-frame-interval \(constants.nominalFrameInterval)",
            "# delta-t-tolerance \(constants.deltaTTolerance)",
            "# band-edges \(constants.bandEdges.map { "\($0)" }.joined(separator: ","))",
            "# edge-mask-relative-threshold \(constants.edgeMaskRelativeThreshold)",
            "# forward-backward-radius \(constants.forwardBackwardRadius)",
            "# minimum-ordering-samples \(constants.minimumOrderingSamples)",
            "# ordering-margin \(constants.orderingMargin)",
            "# pixel-stride \(constants.pixelStride)",
            // Present and 1 so no reader has to branch on its absence: this
            // file drops no survivor of a pair it kept.
            "# decimation 1",
            "# sampling pair-stride",
            "# pair-stride \(collector.pairStride)",
            "# pairs-seen \(collector.sampler.pairsSeen)",
            "# pairs-kept \(collector.sampler.pairsKept)",
        ]
        for bucket in collector.survivors.keys.sorted() {
            lines.append(
                "# survivors k=\(bucket.separation) class=\(bucket.confidenceClass)"
                    + " band=\(bucket.band) \(collector.survivors[bucket]!)"
            )
        }
        for frame in collector.intrinsics.keys.sorted() {
            let scaled = collector.intrinsics[frame]!
            lines.append(
                "# intrinsics \(frame) \(scaled.focalLengthX) \(scaled.focalLengthY)"
                    + " \(scaled.principalPointX) \(scaled.principalPointY)"
            )
        }
        lines.append("# columns \(geometryColumns)")
        lines.append(contentsOf: collector.rows)
        lines.append("")
        try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)

        print("  --- geometry (deterministic) ---")
        print(row("pair stride", "\(collector.pairStride)"))
        print(row("pairs", "\(collector.sampler.pairsKept) kept of \(collector.sampler.pairsSeen)"))
        print(row("survivors", "\(collector.survivors.values.reduce(0, +))"))
        print(row("rows kept", "\(collector.rows.count)"))
        print(row("frames", "\(collector.intrinsics.count)"))
        print(row("wrote", output.path))
        print(row("privacy", "per-pixel rows -- keep local, never commit"))
    }

    /// One container, one file: `#` provenance header -- schema tag, session,
    /// every registered constant, decimation, per-bucket survivor counts --
    /// then bare `k,delta_t,class,depth,delta` rows a numpy `loadtxt` reads
    /// with `comments='#'`. The writer lives in the probe, never the library:
    /// the `InteropProbe --dump` precedent.
    static func writeObservations(
        _ collector: ObservationCollector,
        to output: URL,
        sessionID: UUID,
        constants: Calibration.Constants
    ) throws {
        var lines: [String] = [
            "# skewline-observations/1",
            "# session \(sessionID.uuidString)",
            "# separations \(constants.separations.map(String.init).joined(separator: ","))",
            "# nominal-frame-interval \(constants.nominalFrameInterval)",
            "# delta-t-tolerance \(constants.deltaTTolerance)",
            "# band-edges \(constants.bandEdges.map { "\($0)" }.joined(separator: ","))",
            "# edge-mask-relative-threshold \(constants.edgeMaskRelativeThreshold)",
            "# forward-backward-radius \(constants.forwardBackwardRadius)",
            "# minimum-ordering-samples \(constants.minimumOrderingSamples)",
            "# ordering-margin \(constants.orderingMargin)",
            "# pixel-stride \(constants.pixelStride)",
            "# decimation \(collector.decimation)",
        ]
        for bucket in collector.survivors.keys.sorted() {
            lines.append(
                "# survivors k=\(bucket.separation) class=\(bucket.confidenceClass)"
                    + " band=\(bucket.band) \(collector.survivors[bucket]!)"
            )
        }
        lines.append("# columns k,delta_t,class,depth,delta")
        lines.append(contentsOf: collector.rows)
        lines.append("")
        try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)

        print("  --- observations (deterministic) ---")
        print(row("decimation", "\(collector.decimation)"))
        print(row("survivors", "\(collector.survivors.values.reduce(0, +))"))
        print(row("rows kept", "\(collector.rows.count)"))
        print(row("wrote", output.path))
    }
}
