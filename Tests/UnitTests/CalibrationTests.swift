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
