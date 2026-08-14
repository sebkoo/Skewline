import Testing
import Foundation
import simd
import Core
import Replay
import Render

/// Fixtures for the cross-frame reprojection analysis. A 9×7 map with fx = 8
/// and the principal point at its center: small enough to hand-compute every
/// pixel's fate, sized so an interior remains after the edge mask's border
/// ring, and power-of-two focal lengths so the expected residuals below are
/// exact in binary32 and equality needs no tolerance.
private let mapWidth = 9
private let mapHeight = 7
private let interiorCount = (9 - 2) * (7 - 2)  // 35
private let borderCount = 9 * 7 - interiorCount  // 28

private func sceneIntrinsics() -> IntrinsicsRecord {
    IntrinsicsRecord(
        focalLengthX: 8,
        focalLengthY: 8,
        principalPointX: 4,
        principalPointY: 3,
        referenceWidth: mapWidth,
        referenceHeight: mapHeight
    )
}

private func packed(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func rawDepthRecord() -> DepthRecord {
    DepthRecord(
        width: mapWidth,
        height: mapHeight,
        encoding: .float32,
        compression: .raw,
        confidence: ConfidenceRecord(
            width: mapWidth,
            height: mapHeight,
            encoding: .uint8,
            compression: .raw
        )
    )
}

private func translation(_ x: Float, _ y: Float, _ z: Float) -> Transform4x4 {
    Transform4x4(
        column0: SIMD4(1, 0, 0, 0),
        column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(0, 0, 1, 0),
        column3: SIMD4(x, y, z, 1)
    )
}

private struct SceneFrame {
    var timestamp: TimeInterval
    var depths: [Float]
    var confidences: [UInt8]
    var pose: Transform4x4
    var intrinsics: IntrinsicsRecord = sceneIntrinsics()

    init(
        timestamp: TimeInterval,
        depth: Float,
        confidence: UInt8 = 2,
        pose: Transform4x4 = .identity
    ) {
        self.timestamp = timestamp
        self.depths = [Float](repeating: depth, count: mapWidth * mapHeight)
        self.confidences = [UInt8](repeating: confidence, count: mapWidth * mapHeight)
        self.pose = pose
    }
}

/// Writes the frames as a container, analyzes it, removes it. The container
/// must outlive `analyze` because payloads are read lazily per frame.
private func analyze(
    _ frames: [SceneFrame],
    constants: Calibration.Constants = testConstants()
) throws -> Calibration.Report {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SessionContainer.pathExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    try write(frames, to: url)
    return try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url),
        constants: constants
    )
}

private func write(_ frames: [SceneFrame], to url: URL) throws {
    let writer = try SessionContainer.Writer(creatingAt: url)
    for frame in frames {
        try writer.append(
            Data([0xFF]),
            depth: SessionContainer.DepthPayload(
                depth: packed(frame.depths),
                confidence: Data(frame.confidences)
            )
        )
    }
    let session = CaptureSession(
        observations: frames.map {
            PoseObservation(
                timestamp: $0.timestamp,
                transform: $0.pose,
                covariance: .zero,
                trackingQuality: .limited(.insufficientFeatures)
            )
        },
        frames: frames.map {
            FrameRecord(
                timestamp: $0.timestamp,
                width: mapWidth,
                height: mapHeight,
                encoding: .jpeg,
                depth: rawDepthRecord(),
                intrinsics: $0.intrinsics
            )
        }
    )
    try writer.finalize(session: session)
}

private func testConstants(separations: [Int] = [1]) -> Calibration.Constants {
    var constants = Calibration.Constants()
    constants.separations = separations
    return constants
}

/// Every considered pixel lands in exactly one filter count or survives --
/// the conservation the registered filter order exists to make well-defined.
private func attributed(_ result: Calibration.SeparationResult) -> Int {
    let filters = result.filters
    let grids = [
        filters.sourceEdgeMask, filters.behindCamera, filters.outOfFrame,
        filters.targetDepthInvalid, filters.targetEdgeMask,
        filters.classMismatch, filters.forwardBackward,
    ]
    return filters.sourceDepthInvalid.reduce(0, +)
        + filters.sourceClassOutOfDomain
        + filters.sourceOutOfBand.reduce(0, +)
        + grids.reduce(0) { $0 + $1.joined().reduce(0, +) }
        + result.buckets.joined().reduce(0) { $0 + $1.count }
}

// MARK: - Two-frame identities

@Test func identicalIdentityFramesDisagreeByExactlyZero() throws {
    let step = 1.0 / 30.0
    let report = try analyze([
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: step, depth: 1),
    ])

    #expect(report.eligibility.eligible == 2)
    let k1 = try #require(report.separations.first)
    #expect(k1.pairsFormed == 1)
    #expect(k1.pairsExcludedByDeltaT == 0)
    #expect(k1.medianBaseline == 0)

    // Constant depth: only the border ring is masked, and depth 1.0 lands in
    // the [1,2) band. The 35 interior samples reproject onto themselves.
    #expect(k1.filters.sourceEdgeMask[2][1] == borderCount)
    let bucket = k1.buckets[2][1]
    #expect(bucket.count == interiorCount)
    #expect(bucket.medianAbs == 0)
    #expect(bucket.medianSigned == 0)
    #expect(bucket.mad == 0)
    #expect(attributed(k1) == mapWidth * mapHeight)

    // The sensitivity variants are supersets built in the same pass.
    let maskOff = try #require(k1.bucketsWithoutEdgeMask)
    #expect(maskOff[2][1].count == mapWidth * mapHeight)
    #expect(k1.bucketsWithoutForwardBackward[2][1].count == interiorCount)
    let matchOff = try #require(k1.bucketsWithoutClassMatch)
    #expect(matchOff[2][1].count == interiorCount)
}

/// Equal but non-identity poses: the relative transform is
/// `simd_inverse(M) * M`, identity only to within ulps -- the noise floor
/// the general 4×4 inverse sets under every measured residual. A rotation
/// whose sines are not exact in `Float` keeps the inverse from degenerating
/// into the exact case.
@Test func equalNonIdentityPosesDisagreeOnlyAtUlpScale() throws {
    let angle: Float = 1
    let pose = Transform4x4(
        column0: SIMD4(cos(angle), 0, -sin(angle), 0),
        column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(sin(angle), 0, cos(angle), 0),
        column3: SIMD4(10, 20, 30, 1)
    )
    let report = try analyze([
        SceneFrame(timestamp: 0, depth: 1, pose: pose),
        SceneFrame(timestamp: 1.0 / 30.0, depth: 1, pose: pose),
    ])
    let bucket = try #require(report.separations.first).buckets[2][1]
    #expect(bucket.count == interiorCount)
    #expect(bucket.medianAbs < 1e-5)
}

/// The hand-computed residual. Camera j sits 0.25 m forward of camera i
/// along the optical axis, so geometry predicts 0.75 m where sensor j
/// reports 1.0 -- every value exact in binary32, so the disagreement is
/// exactly +0.25 m on every sample that survives.
@Test func knownForwardTranslationYieldsTheHandComputedResidual() throws {
    let report = try analyze([
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: 1.0 / 30.0, depth: 1, pose: translation(0, 0, -0.25)),
    ])
    let k1 = try #require(report.separations.first)
    #expect(k1.medianBaseline == 0.25)

    // Interior sources whose projection lands on frame j's border ring are
    // target-edge rejections: x ∈ {1, 7} and y ∈ {1, 5} map to border
    // columns and rows under the 1/0.75 magnification, leaving a 5×3 core.
    #expect(k1.filters.sourceEdgeMask[2][1] == borderCount)
    #expect(k1.filters.targetEdgeMask[2][1] == 20)
    let bucket = k1.buckets[2][1]
    #expect(bucket.count == 15)
    #expect(bucket.medianAbs == 0.25)
    #expect(bucket.medianSigned == 0.25)
    #expect(bucket.mad == 0)
    #expect(attributed(k1) == mapWidth * mapHeight)
}

// MARK: - Filters

/// Occlusion, rejected by the forward-backward check specifically. Camera j
/// is 0.5 m to the right; the source sees a surface at 2 m but frame j
/// reports 0.5 m everywhere -- an occluder. The round trip through the
/// occluder's own depth lands 6 px from the source pixel, and only the
/// fw-bw counts may absorb the loss.
@Test func occludedSamplesAreRejectedByTheForwardBackwardCheck() throws {
    var far = SceneFrame(timestamp: 0, depth: 2)
    far.depths = [Float](repeating: 2, count: mapWidth * mapHeight)
    var near = SceneFrame(timestamp: 1.0 / 30.0, depth: 0.5, pose: translation(0.5, 0, 0))
    near.depths = [Float](repeating: 0.5, count: mapWidth * mapHeight)
    let report = try analyze([far, near])
    let k1 = try #require(report.separations.first)

    // u_j = x - 2 exactly: x = 1 leaves the frame, x = 2 lands on the
    // border ring, x ∈ 3...7 survive to the fw-bw check and fail it.
    #expect(k1.filters.outOfFrame[2][2] == 5)
    #expect(k1.filters.targetEdgeMask[2][2] == 5)
    #expect(k1.filters.forwardBackward[2][2] == 25)
    #expect(k1.buckets[2][2].count == 0)

    // With the filter off the occluded disagreement is visible: |0.5 - 2|.
    let unfiltered = k1.bucketsWithoutForwardBackward[2][2]
    #expect(unfiltered.count == 25)
    #expect(unfiltered.medianAbs == 1.5)
    #expect(unfiltered.medianSigned == -1.5)
    #expect(attributed(k1) == mapWidth * mapHeight)
}

@Test func classMismatchesAreCountedAndReappearWithMatchOff() throws {
    var source = SceneFrame(timestamp: 0, depth: 1)
    for y in 2...3 {
        for x in 3...4 {
            source.confidences[y * mapWidth + x] = 1
        }
    }
    let report = try analyze([source, SceneFrame(timestamp: 1.0 / 30.0, depth: 1)])
    let k1 = try #require(report.separations.first)
    #expect(k1.filters.classMismatch[1][1] == 4)
    #expect(k1.buckets[1][1].count == 0)
    #expect(k1.buckets[2][1].count == interiorCount - 4)
    let matchOff = try #require(k1.bucketsWithoutClassMatch)
    #expect(matchOff[1][1].count == 4)
    #expect(matchOff[2][1].count == interiorCount - 4)
}

@Test func invalidTargetDepthIsRejectedBeforeAnySort() throws {
    let target = SceneFrame(timestamp: 1.0 / 30.0, depth: 1)
    var mutated = target
    mutated.depths[3 * mapWidth + 3] = .nan
    mutated.depths[3 * mapWidth + 4] = 0
    mutated.depths[3 * mapWidth + 5] = -1
    let report = try analyze([SceneFrame(timestamp: 0, depth: 1), mutated])
    let k1 = try #require(report.separations.first)

    // The three invalid pixels are target-depth rejections; their eight
    // valid 4-neighbours become target-edge rejections, because a neighbour
    // that is not a depth is a discontinuity by the registered mask rule.
    #expect(k1.filters.targetDepthInvalid[2][1] == 3)
    #expect(k1.filters.targetEdgeMask[2][1] == 8)
    let bucket = k1.buckets[2][1]
    #expect(bucket.count == interiorCount - 11)
    #expect(bucket.medianAbs == 0)
    #expect(bucket.medianAbs.isFinite)
    #expect(attributed(k1) == mapWidth * mapHeight)
}

@Test func sourceRejectionsAreCountedInRegisteredOrder() throws {
    var source = SceneFrame(timestamp: 0, depth: 1)
    source.depths[2 * mapWidth + 2] = .nan  // filter 1, class high
    source.depths[2 * mapWidth + 3] = 0  // filter 1, class high
    source.confidences[2 * mapWidth + 4] = 5  // filter 2
    source.depths[2 * mapWidth + 5] = 6  // filter 3: beyond the last band edge
    source.depths[2 * mapWidth + 6] = 0.4  // filter 3: below the first
    let report = try analyze([source, SceneFrame(timestamp: 1.0 / 30.0, depth: 1)])
    let k1 = try #require(report.separations.first)
    #expect(k1.filters.sourceDepthInvalid == [0, 0, 2, 0])
    #expect(k1.filters.sourceClassOutOfDomain == 1)
    #expect(k1.filters.sourceOutOfBand == [0, 0, 2])
    #expect(attributed(k1) == mapWidth * mapHeight)
}

@Test func pairsBridgingADroppedFrameAreExcludedByDeltaT() throws {
    let step = 1.0 / 30.0
    let report = try analyze([
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: step, depth: 1),
        SceneFrame(timestamp: 2 * step, depth: 1),
        SceneFrame(timestamp: 6 * step, depth: 1),  // three frames dropped
        SceneFrame(timestamp: 7 * step, depth: 1),
    ])
    let k1 = try #require(report.separations.first)
    #expect(k1.pairsFormed == 4)
    #expect(k1.pairsExcludedByDeltaT == 1)
    #expect(k1.buckets[2][1].count == 3 * interiorCount)
    #expect(k1.medianDeltaT == step)
}

@Test func anisotropicIntrinsicsAreCountedNotFatal() throws {
    var skewed = SceneFrame(timestamp: 1.0 / 30.0, depth: 1)
    skewed.intrinsics.referenceWidth = mapWidth * 2
    let report = try analyze([
        SceneFrame(timestamp: 0, depth: 1),
        skewed,
        SceneFrame(timestamp: 2.0 / 30.0, depth: 1),
    ])
    #expect(report.eligibility.anisotropicIntrinsics == 1)
    #expect(report.eligibility.eligible == 2)

    // The surviving neighbours sit two nominal intervals apart, so the one
    // formable pair falls to the Δt filter -- the count is the assertion.
    let k1 = try #require(report.separations.first)
    #expect(k1.pairsFormed == 1)
    #expect(k1.pairsExcludedByDeltaT == 1)
}

/// The registered rounding rule, observed through the analysis: a lateral
/// shift of exactly half a pixel (fx·t/d = 8 × 0.0625 / 1) puts every
/// projection at u = x − 0.5, and ties round away from zero -- back onto
/// column x. A round-to-even rule would split odd and even columns.
@Test func halfPixelProjectionsRoundAwayFromZero() throws {
    let report = try analyze([
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: 1.0 / 30.0, depth: 1, pose: translation(0.0625, 0, 0)),
    ])
    let k1 = try #require(report.separations.first)
    #expect(k1.buckets[2][1].count == interiorCount)
    #expect(k1.buckets[2][1].medianAbs == 0)
    #expect(Calibration.nearestIndex(2.5) == 3)
    #expect(Calibration.nearestIndex(3.5) == 4)
    #expect(Calibration.nearestIndex(2.4) == 2)
    #expect(Calibration.nearestIndex(-0.5) == -1)
}

// MARK: - The edge mask

@Test func edgeMaskFlagsBordersStepsAndInvalidNeighbours() {
    // A 5×4 map: left columns at 1.0, right at 1.5 -- a 50% step against a
    // 5% threshold -- and one NaN poisoning its neighbourhood.
    var depths: [Float] = [
        1.0, 1.0, 1.5, 1.5, 1.5,
        1.0, 1.0, 1.5, 1.5, 1.5,
        1.0, .nan, 1.5, 1.5, 1.5,
        1.0, 1.0, 1.5, 1.5, 1.5,
    ]
    let mask = Calibration.edgeMask(
        DecodedDepth(width: 5, height: 4, depths: depths, confidences: nil),
        relativeThreshold: 0.05
    )
    // Interior pixels: (1,1) and (2,1) straddle the step; (2,2) does too;
    // (1,2) is the NaN itself; (3,1) and (3,2) have flat 1.5 neighbourhoods.
    #expect(mask[1 * 5 + 1] == true)
    #expect(mask[1 * 5 + 2] == true)
    #expect(mask[2 * 5 + 2] == true)
    #expect(mask[2 * 5 + 1] == true)
    #expect(mask[1 * 5 + 3] == false)
    #expect(mask[2 * 5 + 3] == false)
    // The border ring is always masked: incomplete neighbourhood.
    for x in 0..<5 {
        #expect(mask[x] == true)
        #expect(mask[3 * 5 + x] == true)
    }
    for y in 0..<4 {
        #expect(mask[y * 5] == true)
        #expect(mask[y * 5 + 4] == true)
    }

    // A flat map masks nothing but its border.
    depths = [Float](repeating: 2, count: 20)
    let flat = Calibration.edgeMask(
        DecodedDepth(width: 5, height: 4, depths: depths, confidences: nil),
        relativeThreshold: 0.05
    )
    #expect(flat[1 * 5 + 1] == false)
    #expect(flat[2 * 5 + 3] == false)
}

// MARK: - Statistics

@Test func upperMedianFollowsTheProbePrecedent() {
    #expect(Calibration.upperMedian([3, 1, 2]) == 2)
    #expect(Calibration.upperMedian([1, 2, 3, 4]) == 3)
    #expect(Calibration.upperMedian([]) == nil)
}

@Test func bucketStatisticsMatchHandComputedValues() {
    let stat = Calibration.summarize([-4, 1, 2, 3])
    #expect(stat.count == 4)
    // |Δ| sorted: [1, 2, 3, 4] -> upper median 3; deviations |x - 3|
    // sorted: [0, 1, 1, 2] -> MAD 1; signed sorted: [-4, 1, 2, 3] -> 2.
    #expect(stat.medianAbs == 3)
    #expect(stat.mad == 1)
    #expect(stat.medianSigned == 2)
    #expect(Calibration.summarize([]) == Calibration.BucketStat(
        count: 0, medianAbs: 0, mad: 0, medianSigned: 0
    ))
}

@Test func bandEdgesAreHalfOpen() {
    let edges: [Float] = [0.5, 1, 2, 3, 5]
    #expect(Calibration.bandIndex(0.5, edges: edges) == 0)
    #expect(Calibration.bandIndex(1.0, edges: edges) == 1)
    #expect(Calibration.bandIndex(2.999, edges: edges) == 2)
    #expect(Calibration.bandIndex(3.0, edges: edges) == 3)
    #expect(Calibration.bandIndex(5.0, edges: edges) == nil)
    #expect(Calibration.bandIndex(0.499, edges: edges) == nil)
}

@Test func orderingVerdictsCoverAllFourOutcomes() {
    func stat(_ count: Int, _ median: Float) -> Calibration.BucketStat {
        Calibration.BucketStat(count: count, medianAbs: median, mad: 0, medianSigned: 0)
    }
    #expect(Calibration.orderingVerdict(
        low: stat(20_000, 0.020), medium: stat(20_000, 0.015), high: stat(20_000, 0.010),
        minimumSamples: 10_000, margin: 0.1
    ) == .orderedWithMargin)
    #expect(Calibration.orderingVerdict(
        low: stat(20_000, 0.0155), medium: stat(20_000, 0.015), high: stat(20_000, 0.010),
        minimumSamples: 10_000, margin: 0.1
    ) == .orderedWithoutMargin)
    #expect(Calibration.orderingVerdict(
        low: stat(20_000, 0.010), medium: stat(20_000, 0.015), high: stat(20_000, 0.020),
        minimumSamples: 10_000, margin: 0.1
    ) == .notOrdered)
    #expect(Calibration.orderingVerdict(
        low: stat(9_999, 0.020), medium: stat(20_000, 0.015), high: stat(20_000, 0.010),
        minimumSamples: 10_000, margin: 0.1
    ) == .insufficientSamples)
}

@Test func slopeIsLeastSquaresAndNeedsTwoPoints() {
    #expect(Calibration.slope([(x: 1, y: 1), (x: 2, y: 3), (x: 3, y: 5)]) == 2)
    #expect(Calibration.slope([(x: 1, y: 4), (x: 2, y: 4)]) == 0)
    #expect(Calibration.slope([(x: 1, y: 1)]) == nil)
}

// MARK: - The observation sink, the fit's data seam

private struct SinkKey: Hashable {
    let separation: Int
    let confidenceClass: Int
    let band: Int
}

/// Conservation: the sink's samples, grouped and summarized, must re-derive
/// the report's own buckets exactly -- count, medians and MAD -- across every
/// separation. The export provably is the analysis, not a sibling of it.
@Test func sinkObservationsReDeriveTheReportsOwnBuckets() throws {
    let step = 1.0 / 30.0
    var f0 = SceneFrame(timestamp: 0, depth: 1)
    var f1 = SceneFrame(timestamp: step, depth: 1)
    // A class-1 block mirrored in both frames, so a second class survives
    // the match filter; the later pair sits in a different depth band.
    for y in 2...3 {
        for x in 3...4 {
            f0.confidences[y * mapWidth + x] = 1
            f1.confidences[y * mapWidth + x] = 1
        }
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SessionContainer.pathExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    try write([
        f0, f1,
        SceneFrame(timestamp: 2 * step, depth: 2.5),
        SceneFrame(timestamp: 3 * step, depth: 2.5, pose: translation(0, 0, -0.25)),
    ], to: url)

    let constants = testConstants(separations: [1, 2])
    var observations: [Calibration.Observation] = []
    let report = try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url),
        constants: constants,
        observationSink: { observations.append($0) }
    )

    var grouped: [SinkKey: [Float]] = [:]
    for observation in observations {
        #expect(Calibration.bandIndex(observation.depth, edges: constants.bandEdges)
            == observation.band)
        grouped[
            SinkKey(
                separation: observation.separation,
                confidenceClass: observation.confidenceClass,
                band: observation.band
            ),
            default: []
        ].append(observation.residual)
    }

    var total = 0
    for result in report.separations {
        for classIndex in 0..<3 {
            for band in 0..<(constants.bandEdges.count - 1) {
                let bucket = result.buckets[classIndex][band]
                total += bucket.count
                let key = SinkKey(
                    separation: result.separation,
                    confidenceClass: classIndex,
                    band: band
                )
                let samples = grouped[key] ?? []
                #expect(samples.count == bucket.count)
                #expect(Calibration.summarize(samples) == bucket)
            }
        }
    }
    #expect(observations.count == total)
    // The fixture must exercise more than one bucket for the grouping to
    // mean anything: two classes, two bands, two separations.
    #expect(grouped.keys.count >= 4)
}

/// Observation only: the same container analyzed with the sink nil and
/// attached must produce equal reports -- the sink cannot change a number.
@Test func sinkCannotChangeTheReport() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SessionContainer.pathExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    try write([
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: 1.0 / 30.0, depth: 1, pose: translation(0, 0, -0.25)),
        SceneFrame(timestamp: 2.0 / 30.0, depth: 1, pose: translation(0.03, 0.01, -0.5)),
    ], to: url)
    let withoutSink = try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url)
    )
    var delivered = 0
    let withSink = try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url),
        observationSink: { _ in delivered += 1 }
    )
    #expect(withoutSink == withSink)
    #expect(delivered > 0)
}

/// The occlusion fixture: every interior sample reaches the filter chain and
/// none survives it, so the sink must deliver nothing -- it observes the
/// default buckets, never a sensitivity variant's samples.
@Test func sinkStaysSilentWhenEverySampleIsFiltered() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SessionContainer.pathExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    var far = SceneFrame(timestamp: 0, depth: 2)
    far.depths = [Float](repeating: 2, count: mapWidth * mapHeight)
    var near = SceneFrame(timestamp: 1.0 / 30.0, depth: 0.5, pose: translation(0.5, 0, 0))
    near.depths = [Float](repeating: 0.5, count: mapWidth * mapHeight)
    try write([far, near], to: url)

    var delivered = 0
    let report = try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url),
        constants: testConstants(),
        observationSink: { _ in delivered += 1 }
    )
    let k1 = try #require(report.separations.first)
    #expect(k1.bucketsWithoutForwardBackward[2][2].count == 25)
    #expect(delivered == 0)
}

// MARK: - The identity the seam carries

/// Collects one container's observations through the sink.
private func observations(
    _ frames: [SceneFrame],
    constants: Calibration.Constants = testConstants()
) throws -> [Calibration.Observation] {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SessionContainer.pathExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    try write(frames, to: url)
    var collected: [Calibration.Observation] = []
    _ = try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url),
        constants: constants,
        observationSink: { collected.append($0) }
    )
    return collected
}

/// A moving fixture that survives the chain at two separations, so identity
/// is exercised across more than one pair.
private func movingFrames() -> [SceneFrame] {
    [
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: 1.0 / 30.0, depth: 1, pose: translation(0, 0, -0.25)),
        SceneFrame(timestamp: 2.0 / 30.0, depth: 1, pose: translation(0.03, 0.01, -0.5)),
    ]
}

/// Identity that is not unique is not identity: within one frame pair, no
/// two observations may name the same source pixel.
@Test func sinkObservationsCarryDistinctPixelIdentity() throws {
    let collected = try observations(movingFrames())
    #expect(!collected.isEmpty)
    var seen: Set<[Int]> = []
    for observation in collected {
        #expect(observation.sourceX >= 0 && observation.sourceX < mapWidth)
        #expect(observation.sourceY >= 0 && observation.sourceY < mapHeight)
        let key = [
            observation.separation,
            observation.sourceFrame,
            observation.targetFrame,
            observation.sourceX,
            observation.sourceY,
        ]
        #expect(seen.insert(key).inserted, "two observations name one source pixel of one pair")
    }
}

/// The pixel the residual was measured at, pinned on the fixture where the
/// answer is known by construction: with equal poses every source pixel
/// projects onto itself and the round trip returns to it exactly.
///
/// This is the test the transposition check lives in. A swapped
/// `targetX`/`targetY` still yields plausible coordinates, a plausible
/// separation and a plausible ratio, and nothing else in this suite or in the
/// Python harness would go red -- so the assertion is made here, on a **9×7**
/// map, which is non-square precisely so a transposition is detectable. The
/// last expectation proves the fixture can detect one rather than assuming it.
@Test func theProjectedPixelIsTheOneTheResidualUsed() throws {
    let collected = try observations([
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: 1.0 / 30.0, depth: 1),
    ])
    #expect(!collected.isEmpty)
    for observation in collected {
        #expect(observation.targetX == observation.sourceX)
        #expect(observation.targetY == observation.sourceY)
        #expect(observation.roundTripX == 0)
        #expect(observation.roundTripY == 0)
    }
    #expect(
        collected.contains { $0.sourceX != $0.sourceY },
        "the fixture never separates column from row, so it could not catch a transposition"
    )
}

/// Two real frames, named in the session's own index space rather than the
/// eligible list's -- and `targetFrame - sourceFrame` is not asserted to be
/// `separation`, because `k` counts eligible frames and the two coincide only
/// while every frame is eligible.
@Test func pairIdentityNamesTwoRealFrames() throws {
    let frames = movingFrames()
    let collected = try observations(frames, constants: testConstants(separations: [1, 2]))
    #expect(!collected.isEmpty)
    for observation in collected {
        #expect(observation.sourceFrame >= 0)
        #expect(observation.targetFrame < frames.count)
        #expect(observation.sourceFrame < observation.targetFrame)
    }
    #expect(Set(collected.map(\.separation)) == [1, 2])
}

/// The intrinsics riding each observation are that source frame's own, so an
/// exporter's per-frame table is a projection of the emitted stream rather
/// than a second path that can disagree with it.
@Test func eachObservationCarriesItsSourceFramesIntrinsics() throws {
    let expected = try ScaledIntrinsics.scaling(
        sceneIntrinsics(), toWidth: mapWidth, height: mapHeight
    )
    let collected = try observations(movingFrames())
    #expect(!collected.isEmpty)
    for observation in collected {
        #expect(observation.sourceIntrinsics == expected)
    }
}

/// The censoring, made visible in the suite rather than only in the entry:
/// the forward-backward gate is a *filter*, so every observation that exists
/// carries a round trip inside the registered radius by construction. Any
/// statistic of that displacement is truncated from above, which is why the
/// lateral estimand is reportable only beside this bound.
@Test func everyObservationsRoundTripIsInsideTheRegisteredRadius() throws {
    let constants = testConstants()
    let radius = constants.forwardBackwardRadius
    let collected = try observations(movingFrames(), constants: constants)
    #expect(!collected.isEmpty)
    for observation in collected {
        let squared = observation.roundTripX * observation.roundTripX
            + observation.roundTripY * observation.roundTripY
        #expect(squared <= radius * radius)
        #expect(observation.roundTripX.isFinite && observation.roundTripY.isFinite)
    }
}

// MARK: - Determinism

@Test func analysisByteReproducesItsOwnReport() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SessionContainer.pathExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    try write([
        SceneFrame(timestamp: 0, depth: 1),
        SceneFrame(timestamp: 1.0 / 30.0, depth: 1, pose: translation(0, 0, -0.25)),
        SceneFrame(timestamp: 2.0 / 30.0, depth: 1, pose: translation(0.03, 0.01, -0.5)),
    ], to: url)
    let first = try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url)
    )
    let second = try Calibration.analyze(
        reader: try SessionContainer.Reader(contentsOf: url)
    )
    #expect(first == second)
}
