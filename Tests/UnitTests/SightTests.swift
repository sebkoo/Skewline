import Testing
import Foundation
import Model
import Sight

// The consumer's edge, tested where the phone's copy of it cannot be. Nothing
// here needs a sensor: a depth sample is a `Float` and a confidence is a
// `UInt8`, which is the whole reason this arithmetic lives in the package
// rather than in a screen.
//
// The synthetic fixtures come from `ModelFixture`, so a refit of the committed
// artifact cannot turn these red, and the class fixtures differ from each
// other on purpose -- a mapping that sent 0 to medium would otherwise pass.

private func syntheticModel() throws -> FittedModel {
    try FittedModel(decoding: Data(ModelFixture.artifact().utf8))
}

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // Tests/UnitTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // the repository root

private func committedModel() throws -> FittedModel {
    let url = repositoryRoot.appending(path: "Fit/model.json")
    #expect(
        FileManager.default.fileExists(atPath: url.path()),
        "the committed artifact is missing at \(url.path())"
    )
    return try FittedModel(decoding: try Data(contentsOf: url))
}

// MARK: - The sensor's integers meeting the artifact's names

/// The mapping this module exists for, pinned class by class rather than in
/// aggregate: each raw value has to reach the class carrying its own numbers,
/// so a transposition goes red instead of averaging out.
@Test func eachRawConfidenceReachesItsOwnClass() throws {
    let model = try syntheticModel()
    let depth: Float = 2.0
    #expect(model.sighting(depthMeters: depth, rawConfidence: 0)
        == .model(model.estimate(for: .low, atDepthMeters: 2.0)))
    #expect(model.sighting(depthMeters: depth, rawConfidence: 1)
        == .model(model.estimate(for: .medium, atDepthMeters: 2.0)))
    #expect(model.sighting(depthMeters: depth, rawConfidence: 2)
        == .model(model.estimate(for: .high, atDepthMeters: 2.0)))

    // And the three fixtures really do differ, or the three lines above would
    // hold for any mapping at all.
    let answers = [UInt8(0), 1, 2].map {
        model.sighting(depthMeters: depth, rawConfidence: $0).medianPairwiseDisagreementMeters
    }
    #expect(Set(answers.compactMap { $0 }).count == 3)
}

@Test func aConfidenceTheArtifactHasNoClassForIsItsOwnSilence() throws {
    let model = try syntheticModel()
    #expect(model.sighting(depthMeters: 2.0, rawConfidence: 3)
        == .unknownConfidenceClass(rawValue: 3))
    #expect(model.sighting(depthMeters: 2.0, rawConfidence: 255)
        == .unknownConfidenceClass(rawValue: 255))
}

/// Zero, negative and non-finite samples are the sensor saying nothing came
/// back -- the same guard the calibration run applies before it will use a
/// sample at all.
@Test func aPixelWithNoReturnIsRefusedBeforeTheModelIsConsulted() throws {
    let model = try syntheticModel()
    for sample: Float in [0, -0.0, -1.5, .nan, .infinity, -.infinity, .signalingNaN] {
        #expect(model.sighting(depthMeters: sample, rawConfidence: 1) == .noDepthReturned)
    }
}

/// Depth is checked first on purpose: a pixel with no return has no reading,
/// so the class the sensor stamped on it describes nothing and naming that
/// class as the finding would be the wrong one of the two.
@Test func depthIsCheckedBeforeClass() throws {
    let model = try syntheticModel()
    #expect(model.sighting(depthMeters: 0, rawConfidence: 200) == .noDepthReturned)
}

// MARK: - The model's own silences, carried rather than flattened

@Test func theModelsTwoSilencesArriveAsTheModelsOwn() throws {
    let model = try FittedModel(decoding: Data(ModelFixture.artifact(
        classes: ModelFixture.classes(high: ModelFixture.refused(
            table: #"{"edges": [0.5, 1.0, 5.0], "medians": [null, 0.004]}"#
        ))
    ).utf8))
    #expect(model.sighting(depthMeters: 0.75, rawConfidence: 2)
        == .model(.refusedBandWithoutSamples))
    #expect(model.sighting(depthMeters: 6.0, rawConfidence: 2)
        == .model(.refusedOutsideDepthDomain))
}

/// A class whose fit was refused still answers, and it answers through this
/// module unchanged -- which is what keeping the banded table bought.
@Test func aRefusedClassStillAnswersThroughASighting() throws {
    let model = try syntheticModel()
    guard case .model(.fromBandedTable(let meters)) =
        model.sighting(depthMeters: 2.5, rawConfidence: 2) else {
        Issue.record("the refused class did not answer from its table")
        return
    }
    #expect(meters > 0)
}

/// The half-open depth domain, crossed by the `Float` a sensor delivers rather
/// than the `Double` the artifact carries: 0.5 answers, 5.0 refuses, and the
/// conversion does not move either edge.
@Test func theDomainStaysHalfOpenAcrossTheSensorsFloat() throws {
    let model = try syntheticModel()
    for raw: UInt8 in [0, 1, 2] {
        #expect(model.sighting(depthMeters: Float(0.5), rawConfidence: raw)
            .medianPairwiseDisagreementMeters != nil)
        #expect(model.sighting(depthMeters: Float(5.0), rawConfidence: raw)
            == .model(.refusedOutsideDepthDomain))
        #expect(model.sighting(depthMeters: Float(0.4), rawConfidence: raw)
            == .model(.refusedOutsideDepthDomain))
    }
}

/// Every silence hands back no number, and they stay four distinct findings
/// while doing it.
@Test func everySilenceIsNumberlessAndNoneOfThemIsAnother() throws {
    let model = try syntheticModel()
    let silences: [Sighting] = [
        .noDepthReturned,
        .unknownConfidenceClass(rawValue: 7),
        .model(.refusedBandWithoutSamples),
        .model(.refusedOutsideDepthDomain),
    ]
    for silence in silences {
        #expect(silence.medianPairwiseDisagreementMeters == nil)
    }
    for (first, second) in silences.indices.flatMap({ i in
        silences.indices.dropFirst(i + 1).map { (i, $0) }
    }) {
        #expect(silences[first] != silences[second])
    }
    #expect(model.sighting(depthMeters: 2.0, rawConfidence: 0)
        .medianPairwiseDisagreementMeters != nil)
}

// MARK: - The artifact this repository actually ships

/// Against the committed model, not a fixture: every class the sensor can
/// report answers inside the domain and refuses outside it. A relation, not a
/// transcribed number, so a refit leaves it green.
@Test func theCommittedArtifactAnswersEverySensorClassInsideTheDomain() throws {
    let model = try committedModel()
    for raw: UInt8 in [0, 1, 2] {
        #expect(model.sighting(depthMeters: 2.0, rawConfidence: raw)
            .medianPairwiseDisagreementMeters != nil)
        #expect(model.sighting(depthMeters: 5.0, rawConfidence: raw)
            == .model(.refusedOutsideDepthDomain))
    }
}

// MARK: - The half of a tap that is arithmetic

@Test func aMapWithNoPixelsIsNotAGrid() {
    #expect(DepthMapGrid(width: 0, height: 4) == nil)
    #expect(DepthMapGrid(width: 4, height: 0) == nil)
    #expect(DepthMapGrid(width: -1, height: -1) == nil)
}

@Test func theCornersAreTheFirstAndLastSamples() throws {
    let grid = try #require(DepthMapGrid(width: 256, height: 192))
    let first = try #require(grid.pixel(atNormalizedX: 0, y: 0))
    #expect(first.column == 0)
    #expect(first.row == 0)
    #expect(first.index == 0)
    let last = try #require(grid.pixel(atNormalizedX: 1.0.nextDown, y: 1.0.nextDown))
    #expect(last.column == 255)
    #expect(last.row == 191)
    #expect(last.index == 256 * 192 - 1)
}

/// Half-open on both axes: the far edge belongs to the next map, not to this
/// one's last pixel. The same rule `Range<Double>` gives the depth domain.
@Test func theFarEdgeIsNotOnTheMap() throws {
    let grid = try #require(DepthMapGrid(width: 8, height: 8))
    #expect(grid.pixel(atNormalizedX: 1.0, y: 0.5) == nil)
    #expect(grid.pixel(atNormalizedX: 0.5, y: 1.0) == nil)
    #expect(grid.pixel(atNormalizedX: -0.0001, y: 0.5) == nil)
    #expect(grid.pixel(atNormalizedX: 0.5, y: 12.0) == nil)
}

/// A tap nobody can locate is not on the map, which is the truthful answer and
/// not a clamp to some nearby pixel.
@Test func notANumberIsOffTheMap() throws {
    let grid = try #require(DepthMapGrid(width: 8, height: 8))
    #expect(grid.pixel(atNormalizedX: .nan, y: 0.5) == nil)
    #expect(grid.pixel(atNormalizedX: 0.5, y: .nan) == nil)
}

@Test func theIndexIsRowMajor() throws {
    let grid = try #require(DepthMapGrid(width: 4, height: 3))
    let pixel = try #require(grid.pixel(atNormalizedX: 0.5, y: 0.5))
    #expect(pixel.column == 2)
    #expect(pixel.row == 1)
    // Row-major, so the row is what the width multiplies: 1 * 4 + 2.
    #expect(pixel.index == 6)
}

/// Truncating, not rounding: a point exactly on a pixel's leading edge belongs
/// to that pixel, and a hair before it belongs to the one behind.
@Test func aBoundaryBelongsToThePixelItOpens() throws {
    let grid = try #require(DepthMapGrid(width: 4, height: 4))
    #expect(grid.pixel(atNormalizedX: 0.25, y: 0)?.column == 1)
    #expect(grid.pixel(atNormalizedX: 0.25.nextDown, y: 0)?.column == 0)
    #expect(grid.pixel(atNormalizedX: 0.749, y: 0)?.column == 2)
}

@Test func aSinglePixelMapHasOneSampleAndItIsIndexZero() throws {
    let grid = try #require(DepthMapGrid(width: 1, height: 1))
    #expect(grid.pixel(atNormalizedX: 0, y: 0)?.index == 0)
    #expect(grid.pixel(atNormalizedX: 1.0.nextDown, y: 1.0.nextDown)?.index == 0)
    #expect(grid.pixel(atNormalizedX: 1.0, y: 0) == nil)
}

/// The clamp inside the grid, exercised rather than trusted: the product of a
/// normalized value a hair under 1 and the extent is rounded, and for some
/// extents it rounds up to the extent itself. Without the clamp that truncates
/// to an index one past the end of the buffer.
@Test func aValueAHairUnderOneNeverIndexesPastTheEnd() throws {
    for extent in 1...600 {
        let grid = try #require(DepthMapGrid(width: extent, height: extent))
        let pixel = try #require(grid.pixel(atNormalizedX: 1.0.nextDown, y: 1.0.nextDown))
        #expect(pixel.column == extent - 1)
        #expect(pixel.index == extent * extent - 1)
    }
}

// MARK: - The registered wording

// Pinned string by string, and against a synthetic model rather than the
// committed one so a refit cannot turn them red. The wording moved out of
// `SightProbe` and into `Sight` because two readers need it now; until that
// move it had no test at all, which is why these arrive with it. Every branch
// that carries a number states where the number came from, and every branch
// that carries none says "refused" and why.

private func fourSessionModel(classes: String = ModelFixture.classes()) throws -> FittedModel {
    try FittedModel(decoding: Data(ModelFixture.artifact(
        trainedOn: #"["A", "B", "C", "D"]"#,
        classes: classes
    ).utf8))
}

@Test func anAdoptedFormNamesTheSessionsItWasFittedFrom() throws {
    let model = try fourSessionModel()
    // low is quadratic a=0.02 b=0.01, so 0.02 + 0.01 * 4 at two metres.
    #expect(model.sighting(depthMeters: 2.0, rawConfidence: 0).sentence(from: model)
        == "on the 4 sessions this was fitted from, two views of a point like this"
        + " disagreed by about 0.060000 m")
}

/// A refused class still answers, and the sentence has to say both halves:
/// no form was adopted, *and* here is what its band measured. Collapsing it to
/// either half alone is the conflation `Estimate`'s four cases exist to refuse.
@Test func aRefusedClassSaysSoAndStillAnswers() throws {
    let model = try fourSessionModel()
    // high is the refused fixture, band [2.0, 3.0) holding 0.003.
    let sentence = model.sighting(depthMeters: 2.0, rawConfidence: 2).sentence(from: model)
    #expect(sentence == "no form was adopted for this class; on the 4 sessions this was"
        + " fitted from, its band disagreed by about 0.003000 m")
    #expect(sentence.contains("no form was adopted"))
    #expect(sentence.contains("0.003000"))
}

@Test func everySilenceSaysRefusedAndSaysWhy() throws {
    let sparse = ModelFixture.classes(
        high: ModelFixture.refused(
            table: #"{"edges": [0.5, 1.0, 2.0, 3.0, 5.0], "medians": [0.001, null, 0.003, 0.004]}"#
        )
    )
    let model = try fourSessionModel(classes: sparse)

    #expect(model.sighting(depthMeters: 6.0, rawConfidence: 0).sentence(from: model)
        == "refused: outside the depths this was fitted over, nothing answers")
    #expect(model.sighting(depthMeters: 1.5, rawConfidence: 2).sentence(from: model)
        == "refused: inside the fitted depths, but this band had no samples")
    #expect(model.sighting(depthMeters: 0, rawConfidence: 0).sentence(from: model)
        == "refused: the sensor returned no depth at this pixel")
    #expect(model.sighting(depthMeters: 2.0, rawConfidence: 7).sentence(from: model)
        == "refused: the sensor reported class 7, which no fold was fitted over")
}

/// The scene guard, stated as the property rather than as four string
/// comparisons: the artifact cannot guard scene, so every sentence that hands
/// back a number has to name the sessions it came from. A future branch that
/// answers without that clause goes red here.
@Test func noSentenceHandsBackANumberWithoutItsProvenance() throws {
    let model = try fourSessionModel()
    for raw in [UInt8(0), 1, 2] {
        let sighting = model.sighting(depthMeters: 2.0, rawConfidence: raw)
        let sentence = sighting.sentence(from: model)
        #expect(sighting.medianPairwiseDisagreementMeters != nil)
        #expect(sentence.contains("4 sessions this was fitted from"))
    }
}

/// The count is the artifact's, never a literal: a model naming a different
/// number of sessions says a different number.
@Test func theSessionCountIsReadFromTheArtifact() throws {
    let two = try FittedModel(decoding: Data(
        ModelFixture.artifact(trainedOn: #"["A", "B"]"#).utf8
    ))
    #expect(two.sighting(depthMeters: 2.0, rawConfidence: 0)
        .sentence(from: two).contains("on the 2 sessions"))
}
