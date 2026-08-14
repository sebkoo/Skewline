import Foundation
import simd
import Core
import Replay

/// Cross-frame reprojection: the same surface seen twice, with the
/// disagreement binned by the source pixel's confidence class. A depth pixel
/// of frame i is unprojected through pose i and that frame's own intrinsics,
/// projected into frame i+k through pose i+k and *its* intrinsics, and the
/// depth predicted there is compared against the depth the sensor reported.
/// No ground truth enters: the residual conflates sensor noise with pose
/// error -- which is exactly the drift axis -- while occlusion, motion and
/// mixed pixels are held off by registered filters whose removals are
/// counted per class and band, never silently.
///
/// Everything an assertion could reach lives here rather than in the probe,
/// because executable targets cannot be imported by the test target. The
/// probe formats; this module measures.
public enum Calibration {
    /// The registered constants, defaults exactly as registered in the plan
    /// before any analysis run. The margins, thresholds and tolerances are
    /// conventions fixed in advance of the data, not derived numbers.
    public struct Constants: Sendable {
        /// Frame-index separations k, over the eligible-frame list.
        public var separations: [Int] = [1, 5, 15, 30]

        /// The measured median gap between depth-bearing frames -- 0.0333 s
        /// on every observed container -- that pair Δt is checked against.
        public var nominalFrameInterval: Double = 1.0 / 30.0

        /// A pair whose measured Δt deviates from k times the nominal
        /// interval by more than this fraction is excluded and counted.
        public var deltaTTolerance: Double = 0.25

        /// Half-open depth-band edges in meters, binned by source depth so
        /// range cannot confound class. Outside the outermost edges is
        /// excluded and counted.
        public var bandEdges: [Float] = [0.5, 1, 2, 3, 5]

        /// A pixel is edge-masked when any 4-neighbour's depth differs from
        /// its own by more than this fraction of it -- or is not a valid
        /// depth at all. The border ring, whose neighbourhood is incomplete,
        /// is always masked.
        public var edgeMaskRelativeThreshold: Float = 0.05

        /// The forward-backward gate, in depth pixels: the matched target
        /// sample is unprojected through its own depth and projected back,
        /// and a round trip landing farther than this from the source pixel
        /// is rejected -- occlusion and motion, filtered without
        /// thresholding the depth residual itself.
        public var forwardBackwardRadius: Float = 1.0

        /// A band scores an ordering verdict only when all three classes
        /// carry at least this many surviving samples.
        public var minimumOrderingSamples: Int = 10_000

        /// Adjacent classes must be separated by this relative margin for
        /// the strict ordering to count as ordered *with* margin.
        public var orderingMargin: Float = 0.10

        /// Source-pixel stride, an exploration knob. 1 -- every pixel -- is
        /// the registered analysis.
        public var pixelStride: Int = 1

        public init() {}
    }

    /// One surviving sample, as the fit's data seam sees it. The emission
    /// point is part of the registered schema: an observation is delivered
    /// exactly when a sample survives all ten filters and enters the default
    /// buckets -- never a sensitivity variant's sample, never anything the
    /// report does not count. The export is the registered analysis's own
    /// surviving population, the one the calibration table summarized.
    public struct Observation: Equatable, Sendable {
        /// The pair's frame-index separation k.
        public var separation: Int

        /// The pair's measured Δt in seconds -- not k times the nominal.
        public var deltaT: Double

        /// The source pixel's confidence class, 0/1/2 = low/medium/high.
        public var confidenceClass: Int

        /// The source depth's registered band index.
        public var band: Int

        /// The source depth in meters.
        public var depth: Float

        /// The signed residual in meters: observed minus predicted depth,
        /// the exact value the default buckets accumulate. Axial: planar z
        /// along the *target* camera's optical axis, never a raycast
        /// distance.
        public var residual: Float

        /// The source and target frames' indices in `session.frames`. Two
        /// indices and not one pair id plus k, because `k` counts *eligible*
        /// frames: `targetFrame - sourceFrame` is not always `separation`,
        /// and two observations can only be known to share a frame -- which
        /// is what disqualifies them as an independent pair -- when both
        /// ends are named.
        public var sourceFrame: Int
        public var targetFrame: Int

        /// The source pixel, column and row in the depth map. The identity
        /// the fit's data seam lacked: without it two observations cannot be
        /// known to come from one frame pair, and no separation between two
        /// points is computable.
        public var sourceX: Int
        public var sourceY: Int

        /// The matched target pixel, rounded. Carried because two source
        /// pixels can round to *one* target pixel and then literally share
        /// the `observed` depth their residuals are measured from -- a
        /// coincidence that concentrates at small separation and would
        /// manufacture agreement out of arithmetic.
        public var targetX: Int
        public var targetY: Int

        /// The forward-backward round trip's displacement in source pixels,
        /// the quantity the chain computes and then throws away after
        /// comparing it against `forwardBackwardRadius`. Components rather
        /// than a magnitude: a relative-rotation error's signature is
        /// directional, and a magnitude destroys it.
        ///
        /// Censored by construction. Every observation that exists survived
        /// the gate, so `roundTripX² + roundTripY²` is bounded by the
        /// registered radius and *every* statistic of it -- the median
        /// included -- is biased low. It is reportable only beside that
        /// bound.
        public var roundTripX: Float
        public var roundTripY: Float

        /// The source frame's depth-map-scaled pinhole. Rides each
        /// observation so an exporter's per-frame table is provably a
        /// projection of the emitted stream rather than a second path that
        /// can disagree with it.
        public var sourceIntrinsics: ScaledIntrinsics

        public init(
            separation: Int,
            deltaT: Double,
            confidenceClass: Int,
            band: Int,
            depth: Float,
            residual: Float,
            sourceFrame: Int,
            targetFrame: Int,
            sourceX: Int,
            sourceY: Int,
            targetX: Int,
            targetY: Int,
            roundTripX: Float,
            roundTripY: Float,
            sourceIntrinsics: ScaledIntrinsics
        ) {
            self.separation = separation
            self.deltaT = deltaT
            self.confidenceClass = confidenceClass
            self.band = band
            self.depth = depth
            self.residual = residual
            self.sourceFrame = sourceFrame
            self.targetFrame = targetFrame
            self.sourceX = sourceX
            self.sourceY = sourceY
            self.targetX = targetX
            self.targetY = targetY
            self.roundTripX = roundTripX
            self.roundTripY = roundTripY
            self.sourceIntrinsics = sourceIntrinsics
        }
    }

    /// Robust statistics of one bucket's signed residuals. `medianAbs` and
    /// `mad` describe |Δ|; `medianSigned` keeps the sign so a systematic
    /// bias -- a chain bug, not sensor noise -- stays visible.
    public struct BucketStat: Equatable, Sendable {
        public var count: Int
        public var medianAbs: Float
        public var mad: Float
        public var medianSigned: Float

        public init(count: Int, medianAbs: Float, mad: Float, medianSigned: Float) {
            self.count = count
            self.medianAbs = medianAbs
            self.mad = mad
            self.medianSigned = medianSigned
        }
    }

    /// Removal counts for every registered filter, in registered order --
    /// each considered pixel is attributed to exactly its first failing
    /// filter, which is what makes the counts sum to the considered total.
    /// Shapes follow what each filter can know: `sourceDepthInvalid` fires
    /// before the class-domain check, so it needs a fourth slot for an
    /// invalid-depth pixel whose class is also out of domain, while
    /// `sourceOutOfBand` runs after that check and is per-class; everything
    /// later knows both class and band.
    public struct FilterCounts: Equatable, Sendable {
        /// Filter 1 -- source depth zero, negative or non-finite, per class
        /// low/medium/high/other.
        public var sourceDepthInvalid: [Int]

        /// Filter 2 -- source confidence outside the documented 0/1/2.
        public var sourceClassOutOfDomain: Int

        /// Filter 3 -- source depth outside the registered bands, per class.
        public var sourceOutOfBand: [Int]

        /// Filters 4 through 10, each `[class][band]`.
        public var sourceEdgeMask: [[Int]]
        public var behindCamera: [[Int]]
        public var outOfFrame: [[Int]]
        public var targetDepthInvalid: [[Int]]
        public var targetEdgeMask: [[Int]]
        public var classMismatch: [[Int]]
        public var forwardBackward: [[Int]]

        init(bands: Int) {
            let grid = [[Int]](repeating: [Int](repeating: 0, count: bands), count: 3)
            sourceDepthInvalid = [Int](repeating: 0, count: 4)
            sourceClassOutOfDomain = 0
            sourceOutOfBand = [Int](repeating: 0, count: 3)
            sourceEdgeMask = grid
            behindCamera = grid
            outOfFrame = grid
            targetDepthInvalid = grid
            targetEdgeMask = grid
            classMismatch = grid
            forwardBackward = grid
        }
    }

    /// One separation's measurement. `buckets` is `[class][band]` under the
    /// full registered filter set; the `without*` variants each lift exactly
    /// one filter, accumulated in the same pass -- the sensitivity rows that
    /// keep the filtered numbers falsifiable. The edge-mask and class-match
    /// variants are registered at k = 1 only and are nil elsewhere; the
    /// forward-backward variant rides every k because its truncation bound
    /// tightens as the baseline grows. `pooled` merges the in-band samples
    /// per class for the drift table.
    public struct SeparationResult: Equatable, Sendable {
        public var separation: Int
        public var pairsFormed: Int
        public var pairsExcludedByDeltaT: Int
        public var medianDeltaT: Double
        public var medianBaseline: Float
        public var filters: FilterCounts
        public var buckets: [[BucketStat]]
        public var pooled: [BucketStat]
        public var bucketsWithoutForwardBackward: [[BucketStat]]
        public var pooledWithoutForwardBackward: [BucketStat]
        public var bucketsWithoutEdgeMask: [[BucketStat]]?
        public var bucketsWithoutClassMatch: [[BucketStat]]?
    }

    /// Why frames fell out before any pair formed, the probe's eligibility
    /// categories -- including the anisotropic-intrinsics throw, counted per
    /// frame here rather than aborting the container.
    public struct Eligibility: Equatable, Sendable {
        public var frames: Int
        public var eligible: Int
        public var noDepth: Int
        public var noIntrinsics: Int
        public var noPose: Int
        public var noConfidence: Int
        public var anisotropicIntrinsics: Int
    }

    public struct Report: Equatable, Sendable {
        public var sessionID: UUID
        public var eligibility: Eligibility

        /// Upper median of the eligible frames' depth-scaled fx, the
        /// denominator of the printed forward-backward truncation bound.
        public var medianFocalLengthX: Float

        public var separations: [SeparationResult]
    }

    public enum OrderingVerdict: String, Equatable, Sendable {
        case orderedWithMargin = "ordered with margin"
        case orderedWithoutMargin = "ordered without margin"
        case notOrdered = "not ordered"
        case insufficientSamples = "insufficient samples"
    }

    // MARK: - Pure pieces

    /// The half-open band for a source depth, nil outside the outermost
    /// edges.
    public static func bandIndex(_ depth: Float, edges: [Float]) -> Int? {
        guard let first = edges.first, let last = edges.last,
              depth >= first, depth < last else { return nil }
        for band in 1..<edges.count where depth < edges[band] {
            return band - 1
        }
        return nil
    }

    /// The registered rounding rule for the nearest target pixel: to
    /// nearest, ties away from zero.
    public static func nearestIndex(_ coordinate: Float) -> Int {
        Int(coordinate.rounded())
    }

    /// True where a pixel may be a mixed or discontinuity sample: on the
    /// border ring, beside a 4-neighbour differing by more than the relative
    /// threshold, beside an invalid sample -- or invalid itself, though the
    /// depth-validity filters fire first and keep that value unobserved.
    public static func edgeMask(_ depth: DecodedDepth, relativeThreshold: Float) -> [Bool] {
        let width = depth.width
        let height = depth.height
        var mask = [Bool](repeating: true, count: width * height)
        guard width > 2, height > 2 else { return mask }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let center = depth.depths[index]
                guard center > 0, center.isFinite else { continue }
                let limit = relativeThreshold * center
                var masked = false
                for neighbour in [index - 1, index + 1, index - width, index + width] {
                    let sample = depth.depths[neighbour]
                    guard sample > 0, sample.isFinite, abs(sample - center) <= limit else {
                        masked = true
                        break
                    }
                }
                mask[index] = masked
            }
        }
        return mask
    }

    /// The probe precedent's median: `sorted[count / 2]`, the upper median,
    /// with no averaging of the middle pair.
    public static func upperMedian(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// One bucket's statistics from its signed residuals. MAD is the upper
    /// median of |x − median| over the |Δ| samples.
    public static func summarize(_ signedDeltas: [Float]) -> BucketStat {
        guard !signedDeltas.isEmpty else {
            return BucketStat(count: 0, medianAbs: 0, mad: 0, medianSigned: 0)
        }
        let absolute = signedDeltas.map(abs).sorted()
        let median = absolute[absolute.count / 2]
        let deviations = absolute.map { abs($0 - median) }.sorted()
        return BucketStat(
            count: signedDeltas.count,
            medianAbs: median,
            mad: deviations[deviations.count / 2],
            medianSigned: signedDeltas.sorted()[signedDeltas.count / 2]
        )
    }

    /// The registered pass condition for one band: strict ordering
    /// low > medium > high of median |Δ|, with or without the relative
    /// margin between adjacent classes -- scored only when every class
    /// carries the minimum sample count.
    public static func orderingVerdict(
        low: BucketStat,
        medium: BucketStat,
        high: BucketStat,
        minimumSamples: Int,
        margin: Float
    ) -> OrderingVerdict {
        guard low.count >= minimumSamples, medium.count >= minimumSamples,
              high.count >= minimumSamples else {
            return .insufficientSamples
        }
        guard low.medianAbs > medium.medianAbs, medium.medianAbs > high.medianAbs else {
            return .notOrdered
        }
        let separated = low.medianAbs >= medium.medianAbs * (1 + margin)
            && medium.medianAbs >= high.medianAbs * (1 + margin)
        return separated ? .orderedWithMargin : .orderedWithoutMargin
    }

    /// Least-squares slope through the drift points, nil below two points.
    public static func slope(_ points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        let sxx = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard sxx > 0 else { return nil }
        let sxy = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        return sxy / sxx
    }

    // MARK: - The analysis

    private struct EligibleFrame {
        /// This frame's index in `session.frames`, kept because the pair loop
        /// runs over *eligible* frames and an eligible index means something
        /// different in every container.
        let frameIndex: Int
        let timestamp: TimeInterval
        let intrinsics: ScaledIntrinsics
        let pose: simd_float4x4
        let width: Int
        let height: Int
        let depths: [Float]
        let confidences: [UInt8]
        let mask: [Bool]
    }

    /// Replays one container through the reprojection chain. Deterministic
    /// by construction: fixed frame order, sequential folds, dictionary
    /// lookups but never dictionary iteration, no clocks, no randomness --
    /// the same container byte-reproduces the same report.
    ///
    /// `observationSink`, when non-nil, receives every surviving sample in
    /// the deterministic accumulation order -- observation only, and the
    /// tests hold it there: the report is identical with the sink nil or
    /// attached, and the sink's samples re-derive the report's own buckets.
    public static func analyze(
        reader: SessionContainer.Reader,
        constants: Constants = Constants(),
        observationSink: ((Observation) -> Void)? = nil
    ) throws -> Report {
        precondition(constants.pixelStride >= 1)
        precondition(constants.bandEdges.count >= 2)
        precondition(constants.separations.allSatisfy { $0 >= 1 })
        let session = reader.session
        let bands = constants.bandEdges.count - 1

        // Frame timestamps are members of the pose set on every observed
        // capture, so association is an exact-match lookup -- a miss is
        // counted, never bridged to the nearest neighbour.
        let poseByTimestamp = Dictionary(
            session.observations.map { ($0.timestamp, $0.transform) },
            uniquingKeysWith: { first, _ in first }
        )

        var eligibility = Eligibility(
            frames: session.frames.count, eligible: 0, noDepth: 0, noIntrinsics: 0,
            noPose: 0, noConfidence: 0, anisotropicIntrinsics: 0
        )
        var eligible: [EligibleFrame] = []
        for (index, frame) in session.frames.enumerated() {
            try autoreleasepool {
                guard let depthRecord = frame.depth else {
                    eligibility.noDepth += 1
                    return
                }
                // Read the payload for every frame that has one, whether or
                // not it joins a pair: a container whose bytes cannot be
                // read should fail this probe loudly, not pass it by being
                // ineligible for a different reason.
                let depthData = try reader.depthData(at: index)
                let confidenceData = depthRecord.confidence != nil
                    ? try reader.confidenceData(at: index)
                    : nil
                guard let intrinsics = frame.intrinsics else {
                    eligibility.noIntrinsics += 1
                    return
                }
                guard let pose = poseByTimestamp[frame.timestamp] else {
                    eligibility.noPose += 1
                    return
                }
                guard confidenceData != nil else {
                    eligibility.noConfidence += 1
                    return
                }
                let decoded = try DepthDecoder.decode(
                    record: depthRecord,
                    depthData: depthData,
                    confidenceData: confidenceData
                )
                guard let confidences = decoded.confidences else {
                    eligibility.noConfidence += 1
                    return
                }
                let scaled: ScaledIntrinsics
                do {
                    scaled = try ScaledIntrinsics.scaling(
                        intrinsics, toWidth: decoded.width, height: decoded.height
                    )
                } catch UnprojectionError.anisotropicScale {
                    eligibility.anisotropicIntrinsics += 1
                    return
                }
                eligible.append(EligibleFrame(
                    frameIndex: index,
                    timestamp: frame.timestamp,
                    intrinsics: scaled,
                    pose: pose.simd,
                    width: decoded.width,
                    height: decoded.height,
                    depths: decoded.depths,
                    confidences: confidences,
                    mask: edgeMask(decoded, relativeThreshold: constants.edgeMaskRelativeThreshold)
                ))
            }
        }
        eligibility.eligible = eligible.count

        let medianFx = upperMedian(eligible.map(\.intrinsics.focalLengthX)) ?? 0
        var results: [SeparationResult] = []
        for separation in constants.separations {
            results.append(measure(
                separation: separation,
                eligible: eligible,
                bands: bands,
                constants: constants,
                observationSink: observationSink
            ))
        }
        return Report(
            sessionID: session.id,
            eligibility: eligibility,
            medianFocalLengthX: medianFx,
            separations: results
        )
    }

    private static func measure(
        separation k: Int,
        eligible: [EligibleFrame],
        bands: Int,
        constants: Constants,
        observationSink: ((Observation) -> Void)? = nil
    ) -> SeparationResult {
        // The k = 1 pass carries the registered edge-mask-off and
        // class-match-off sensitivity variants; every pass carries the
        // forward-backward-off variant, whose truncation bound tightens
        // with the baseline.
        let firstSeparationVariants = k == 1
        var filters = FilterCounts(bands: bands)
        let emptyBuckets = [[[Float]]](
            repeating: [[Float]](repeating: [], count: bands), count: 3
        )
        var defaultSamples = emptyBuckets
        var fwbwOffSamples = emptyBuckets
        var maskOffSamples = firstSeparationVariants ? emptyBuckets : []
        var matchOffSamples = firstSeparationVariants ? emptyBuckets : []

        var pairsFormed = 0
        var excluded = 0
        var deltaTs: [Double] = []
        var baselines: [Float] = []
        let nominal = Double(k) * constants.nominalFrameInterval
        let radiusSquared = constants.forwardBackwardRadius * constants.forwardBackwardRadius
        let stride = constants.pixelStride

        for start in eligible.indices.dropLast(k) {
            let source = eligible[start]
            let target = eligible[start + k]
            pairsFormed += 1
            let deltaT = target.timestamp - source.timestamp
            guard abs(deltaT - nominal) <= constants.deltaTTolerance * nominal else {
                excluded += 1
                continue
            }
            deltaTs.append(deltaT)

            // One relative transform per pair, each direction composed the
            // same way from the two poses -- registered, because per-pixel
            // composition rounds differently and the tests pin this one.
            let forward = simd_inverse(target.pose) * source.pose
            let backward = simd_inverse(source.pose) * target.pose
            let translation = forward.columns.3
            baselines.append(simd_length(SIMD3(translation.x, translation.y, translation.z)))

            let width = source.width
            let height = source.height
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let index = y * width + x
                    x += stride

                    // Filters 1-3, before any geometry.
                    let depth = source.depths[index]
                    let rawClass = source.confidences[index]
                    guard depth > 0, depth.isFinite else {
                        filters.sourceDepthInvalid[Int(min(rawClass, 3))] += 1
                        continue
                    }
                    guard rawClass <= 2 else {
                        filters.sourceClassOutOfDomain += 1
                        continue
                    }
                    let sourceClass = Int(rawClass)
                    guard let band = bandIndex(depth, edges: constants.bandEdges) else {
                        filters.sourceOutOfBand[sourceClass] += 1
                        continue
                    }

                    // The chain. A sample that cannot produce a residual is
                    // structural: no variant can keep it, and attribution
                    // follows the registered order -- a masked source
                    // outranks whatever geometry then went wrong.
                    let sourceMasked = source.mask[index]
                    let camera = Unprojector.cameraPoint(
                        x: index % width, y: y, depth: depth, intrinsics: source.intrinsics
                    )
                    let projected = forward * SIMD4(camera.x, camera.y, camera.z, 1)
                    guard let image = Unprojector.imagePoint(
                        camera: SIMD3(projected.x, projected.y, projected.z),
                        intrinsics: target.intrinsics
                    ) else {
                        if sourceMasked {
                            filters.sourceEdgeMask[sourceClass][band] += 1
                        } else {
                            filters.behindCamera[sourceClass][band] += 1
                        }
                        continue
                    }
                    let roundedX = image.x.rounded()
                    let roundedY = image.y.rounded()
                    guard roundedX >= 0, roundedX <= Float(target.width - 1),
                          roundedY >= 0, roundedY <= Float(target.height - 1) else {
                        if sourceMasked {
                            filters.sourceEdgeMask[sourceClass][band] += 1
                        } else {
                            filters.outOfFrame[sourceClass][band] += 1
                        }
                        continue
                    }
                    let targetX = Int(roundedX)
                    let targetY = Int(roundedY)
                    let targetIndex = targetY * target.width + targetX
                    let observed = target.depths[targetIndex]
                    guard observed > 0, observed.isFinite else {
                        if sourceMasked {
                            filters.sourceEdgeMask[sourceClass][band] += 1
                        } else {
                            filters.targetDepthInvalid[sourceClass][band] += 1
                        }
                        continue
                    }
                    let residual = observed - image.depth

                    // The liftable filters, computed as flags so each
                    // variant subtracts exactly one.
                    let targetMasked = target.mask[targetIndex]
                    let mismatched = target.confidences[targetIndex] != rawClass
                    let roundTripFails: Bool
                    // The round trip's displacement, kept rather than
                    // discarded at the comparison: it is the only lateral
                    // disagreement this chain computes. A point with no
                    // image has no displacement, and the filter rejects it,
                    // so no observation ever carries the sentinel.
                    var roundTripX: Float = .nan
                    var roundTripY: Float = .nan
                    let matched = Unprojector.cameraPoint(
                        x: targetX, y: targetY, depth: observed, intrinsics: target.intrinsics
                    )
                    let back = backward * SIMD4(matched.x, matched.y, matched.z, 1)
                    if let returned = Unprojector.imagePoint(
                        camera: SIMD3(back.x, back.y, back.z),
                        intrinsics: source.intrinsics
                    ) {
                        let dx = returned.x - Float(index % width)
                        let dy = returned.y - Float(y)
                        roundTripX = dx
                        roundTripY = dy
                        roundTripFails = !(dx * dx + dy * dy <= radiusSquared)
                    } else {
                        roundTripFails = true
                    }

                    if sourceMasked {
                        filters.sourceEdgeMask[sourceClass][band] += 1
                    } else if targetMasked {
                        filters.targetEdgeMask[sourceClass][band] += 1
                    } else if mismatched {
                        filters.classMismatch[sourceClass][band] += 1
                    } else if roundTripFails {
                        filters.forwardBackward[sourceClass][band] += 1
                    } else {
                        defaultSamples[sourceClass][band].append(residual)
                        // `index % width` and `y`, never `x`: the loop
                        // advances `x` by the stride before the cascade
                        // runs, so `x` here names the next pixel. The round
                        // trip above already computes its source coordinate
                        // the same way, and for the same reason.
                        observationSink?(Observation(
                            separation: k,
                            deltaT: deltaT,
                            confidenceClass: sourceClass,
                            band: band,
                            depth: depth,
                            residual: residual,
                            sourceFrame: source.frameIndex,
                            targetFrame: target.frameIndex,
                            sourceX: index % width,
                            sourceY: y,
                            targetX: targetX,
                            targetY: targetY,
                            roundTripX: roundTripX,
                            roundTripY: roundTripY,
                            sourceIntrinsics: source.intrinsics
                        ))
                    }
                    if !sourceMasked, !targetMasked, !mismatched {
                        fwbwOffSamples[sourceClass][band].append(residual)
                    }
                    if firstSeparationVariants {
                        if !mismatched, !roundTripFails {
                            maskOffSamples[sourceClass][band].append(residual)
                        }
                        if !sourceMasked, !targetMasked, !roundTripFails {
                            matchOffSamples[sourceClass][band].append(residual)
                        }
                    }
                }
                y += stride
            }
        }

        func stats(_ samples: [[[Float]]]) -> [[BucketStat]] {
            samples.map { $0.map(summarize) }
        }
        func pooledStats(_ samples: [[[Float]]]) -> [BucketStat] {
            samples.map { summarize($0.flatMap { $0 }) }
        }
        return SeparationResult(
            separation: k,
            pairsFormed: pairsFormed,
            pairsExcludedByDeltaT: excluded,
            medianDeltaT: deltaTs.isEmpty ? 0 : deltaTs.sorted()[deltaTs.count / 2],
            medianBaseline: upperMedian(baselines) ?? 0,
            filters: filters,
            buckets: stats(defaultSamples),
            pooled: pooledStats(defaultSamples),
            bucketsWithoutForwardBackward: stats(fwbwOffSamples),
            pooledWithoutForwardBackward: pooledStats(fwbwOffSamples),
            bucketsWithoutEdgeMask: firstSeparationVariants ? stats(maskOffSamples) : nil,
            bucketsWithoutClassMatch: firstSeparationVariants ? stats(matchOffSamples) : nil
        )
    }
}
