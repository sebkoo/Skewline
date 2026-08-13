import Testing
import Foundation
import Model

// Every fixture is a JSON literal built here and never a file, so the shapes
// the committed artifact does not contain get exercised anyway: a power form,
// a fold entry disqualified by the positivity gate, and a band with no
// samples. Nothing derives from a capture.

enum ModelFixture {
    static let folds = """
        [{"holdout": "A", "table": 1.0, "forms": {"affine": {"metric": 0.9, "margin": 0.1}}}]
        """

    static let fullTable = """
        {"edges": [0.5, 1.0, 2.0, 3.0, 5.0], "medians": [0.001, 0.002, 0.003, 0.004]}
        """

    static func adopted(
        form: String,
        coefficients: String,
        folds: String = ModelFixture.folds
    ) -> String {
        """
        {"verdict": "adopted", "form": "\(form)", "coefficients": \(coefficients), \
        "folds": \(folds)}
        """
    }

    static func refused(
        table: String = ModelFixture.fullTable,
        folds: String = ModelFixture.folds
    ) -> String {
        """
        {"verdict": "refused", "table": \(table), "folds": \(folds)}
        """
    }

    /// A whole artifact, every field overridable so one malformation can be
    /// introduced at a time.
    static func artifact(
        schema: String = FittedModel.schemaTag,
        units: String = FittedModel.units,
        outsideDomain: String = FittedModel.outsideDomain,
        depthDomain: String = "[0.5, 5.0]",
        trainedOn: String = #"["A"]"#,
        classes: String = ModelFixture.classes()
    ) -> String {
        """
        {
          "schema": "\(schema)",
          "estimand": "the registered wording",
          "units": "\(units)",
          "outsideDomain": "\(outsideDomain)",
          "depthDomain": \(depthDomain),
          "trainedOn": \(trainedOn),
          "export": [{"session": "A", "decimation": 64}],
          "classes": \(classes)
        }
        """
    }

    static func classes(
        low: String = ModelFixture.adopted(form: "quadratic", coefficients: #"{"a": 0.02, "b": 0.01}"#),
        medium: String = ModelFixture.adopted(form: "affine", coefficients: #"{"a": 0.01, "b": 0.003}"#),
        high: String = ModelFixture.refused(),
        extra: String = ""
    ) -> String {
        """
        {"low": \(low), "medium": \(medium), "high": \(high)\(extra)}
        """
    }
}

private func decoded(_ json: String) throws -> FittedModel {
    try FittedModel(decoding: Data(json.utf8))
}

/// The refusal a fixture provokes, `nil` when it decodes -- so a test can pin
/// the exact rejection kind without matching message prose.
private func rejection(_ json: String) throws -> ModelReadError.Kind? {
    do {
        _ = try FittedModel(decoding: Data(json.utf8))
        return nil
    } catch let error as ModelReadError {
        return error.kind
    }
}

// MARK: - The registered shape

@Test func decodesTheRegisteredShape() throws {
    let model = try decoded(ModelFixture.artifact())
    #expect(model.depthDomain == 0.5..<5.0)
    #expect(model.estimand == "the registered wording")
    #expect(model.trainedOn == ["A"])
    #expect(model.export == [Provenance(session: "A", decimation: 64)])
    #expect(model.classes[.low].verdict == .adopted(.quadratic(a: 0.02, b: 0.01)))
    #expect(model.classes[.medium].verdict == .adopted(.affine(a: 0.01, b: 0.003)))
    if case .adopted = model.classes[.high].verdict {
        Issue.record("the high class was refused in the fixture")
    }
}

// MARK: - The tag, checked before anything is believed

@Test func aWrongSchemaIsRefusedBeforeAnyOtherFieldIsRead() throws {
    // Three things wrong at once; the tag is the one reported, which is what
    // "checked before anything is believed" has to mean mechanically.
    #expect(try rejection(ModelFixture.artifact(
        schema: "skewline-fit/2",
        units: "furlongs",
        depthDomain: "[]"
    )) == .wrongSchema)
}

@Test func anArtifactWithNoSchemaFieldIsRefused() throws {
    #expect(try rejection("""
        {"estimand": "x", "units": "meters", "outsideDomain": "refuse",
         "depthDomain": [0.5, 5.0], "trainedOn": [], "export": [],
         "classes": \(ModelFixture.classes())}
        """) == .wrongSchema)
}

@Test func aNonStringSchemaIsSimplyNotTheTag() throws {
    #expect(try rejection(ModelFixture.artifact().replacingOccurrences(
        of: "\"\(FittedModel.schemaTag)\"", with: "1"
    )) == .wrongSchema)
}

@Test func bytesThatAreNotJSONAreRefused() throws {
    #expect(try rejection("not json at all") == .notJSON)
}

// MARK: - The two fields whose meaning this reader hard-codes

@Test func unitsOtherThanMetersAreRefused() throws {
    #expect(try rejection(ModelFixture.artifact(units: "millimeters")) == .wrongUnits)
}

@Test func anExtrapolatingArtifactIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(outsideDomain: "extrapolate")) == .wrongOutsideDomain)
}

@Test func aMalformedDepthDomainIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(depthDomain: "[0.5, 5.0, 9.0]")) == .malformedDomain)
    #expect(try rejection(ModelFixture.artifact(depthDomain: "[5.0, 0.5]")) == .malformedDomain)
    #expect(try rejection(ModelFixture.artifact(depthDomain: "[2.0, 2.0]")) == .malformedDomain)
}

// MARK: - The forms, one evaluation each

@Test func theAffineFormEvaluatesAsWritten() throws {
    let model = try decoded(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(form: "affine", coefficients: #"{"a": 0.02, "b": 0.01}"#)
    )))
    #expect(model.estimate(for: .low, atDepthMeters: 3.0)
        == .fromAdoptedForm(medianPairwiseDisagreementMeters: 0.02 + 0.01 * 3.0))
}

@Test func theQuadraticFormEvaluatesAsWritten() throws {
    let model = try decoded(ModelFixture.artifact())
    #expect(model.estimate(for: .low, atDepthMeters: 3.0)
        == .fromAdoptedForm(medianPairwiseDisagreementMeters: 0.02 + 0.01 * 3.0 * 3.0))
}

/// The shape no committed instance exercises: the power form's coefficients
/// are `{a, p}`, not the `{a, b}` both adopted classes carry.
@Test func thePowerFormDecodesAndEvaluatesFromItsOwnCoefficients() throws {
    let model = try decoded(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(form: "power", coefficients: #"{"a": 0.02, "p": 1.5}"#)
    )))
    #expect(model.classes[.low].verdict == .adopted(.power(a: 0.02, p: 1.5)))
    #expect(model.estimate(for: .low, atDepthMeters: 2.0)
        == .fromAdoptedForm(medianPairwiseDisagreementMeters: 0.02 * pow(2.0, 1.5)))
}

@Test func anUnnameableFormIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(form: "cubic", coefficients: #"{"a": 0.02, "b": 0.01}"#)
    ))) == .malformedForm)
}

@Test func aFormMissingACoefficientIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(form: "quadratic", coefficients: #"{"a": 0.02}"#)
    ))) == .malformedForm)
}

/// A coefficient this form is not evaluated from would be silently ignored,
/// which is the coercion this reader refuses to make.
@Test func aFormCarryingACoefficientItDoesNotUseIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(form: "quadratic", coefficients: #"{"a": 0.02, "b": 0.01, "p": 2.0}"#)
    ))) == .malformedForm)
}

@Test func anUnknownVerdictIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        low: #"{"verdict": "pending", "folds": []}"#
    ))) == .unknownVerdict)
}

// MARK: - The folds

/// The shape no committed instance exercises: the positivity gate rejected a
/// form before selection ever scored it, so its entry carries no metric.
@Test func aDisqualifiedFoldEntryDecodes() throws {
    let model = try decoded(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(
            form: "quadratic",
            coefficients: #"{"a": 0.02, "b": 0.01}"#,
            folds: """
                [{"holdout": "A", "table": 1.0, "forms": {
                    "affine": {"metric": 0.9, "margin": 0.1},
                    "power": {"disqualified": true}}}]
                """
        )
    )))
    let fold = try #require(model.classes[.low].folds.first)
    #expect(fold.holdout == "A")
    #expect(fold.tableMetric == 1.0)
    #expect(fold.forms["affine"] == .scored(metric: 0.9, margin: 0.1))
    #expect(fold.forms["power"] == .disqualified)
}

@Test func aFoldEntryThatIsBothScoredAndDisqualifiedIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(
            form: "quadratic",
            coefficients: #"{"a": 0.02, "b": 0.01}"#,
            folds: """
                [{"holdout": "A", "table": 1.0, "forms": {
                    "affine": {"metric": 0.9, "margin": 0.1, "disqualified": true}}}]
                """
        )
    ))) == .malformedFold)
}

@Test func aFoldEntryThatIsNeitherIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(
            form: "quadratic",
            coefficients: #"{"a": 0.02, "b": 0.01}"#,
            folds: #"[{"holdout": "A", "table": 1.0, "forms": {"affine": {}}}]"#
        )
    ))) == .malformedFold)
}

/// A fold's form name stays a string on purpose: an adopted form must be
/// understood to be evaluated, while a fold entry is a diagnostic, and a later
/// fit reporting a fourth candidate must not cost a consumer the whole model.
@Test func aFoldMayNameACandidateThisReaderCannotEvaluate() throws {
    let model = try decoded(ModelFixture.artifact(classes: ModelFixture.classes(
        low: ModelFixture.adopted(
            form: "quadratic",
            coefficients: #"{"a": 0.02, "b": 0.01}"#,
            folds: """
                [{"holdout": "A", "table": 1.0, "forms": {
                    "logarithmic": {"metric": 0.9, "margin": 0.1}}}]
                """
        )
    )))
    #expect(try #require(model.classes[.low].folds.first).forms["logarithmic"]
        == .scored(metric: 0.9, margin: 0.1))
}

// MARK: - Refused is not unavailable

@Test func aRefusedClassStillAnswersFromItsTable() throws {
    let model = try decoded(ModelFixture.artifact())
    #expect(model.estimate(for: .high, atDepthMeters: 2.5)
        == .fromBandedTable(medianPairwiseDisagreementMeters: 0.003))
}

/// The shape no committed instance exercises: `fit_table` appends null for a
/// band with no samples, so that band has no median to hand back -- a
/// different silence from being outside the domain, and the type says which.
@Test func aBandWithNoSamplesRefusesWithoutTakingTheRestOfTheTableDown() throws {
    let model = try decoded(ModelFixture.artifact(classes: ModelFixture.classes(
        high: ModelFixture.refused(table: """
            {"edges": [0.5, 1.0, 2.0, 3.0, 5.0], "medians": [null, 0.002, 0.003, 0.004]}
            """)
    )))
    #expect(model.estimate(for: .high, atDepthMeters: 0.7) == .refusedBandWithoutSamples)
    #expect(model.estimate(for: .high, atDepthMeters: 1.5)
        == .fromBandedTable(medianPairwiseDisagreementMeters: 0.002))
}

@Test func theTwoRefusalsAreDistinguishableAtTheCallSite() throws {
    let model = try decoded(ModelFixture.artifact(classes: ModelFixture.classes(
        high: ModelFixture.refused(table: """
            {"edges": [0.5, 1.0, 2.0, 3.0, 5.0], "medians": [null, 0.002, 0.003, 0.004]}
            """)
    )))
    #expect(model.estimate(for: .high, atDepthMeters: 0.7) == .refusedBandWithoutSamples)
    #expect(model.estimate(for: .high, atDepthMeters: 0.4) == .refusedOutsideDepthDomain)
    #expect(model.estimate(for: .high, atDepthMeters: 0.7).medianPairwiseDisagreementMeters == nil)
    #expect(model.estimate(for: .high, atDepthMeters: 0.4).medianPairwiseDisagreementMeters == nil)
    #expect(model.estimate(for: .high, atDepthMeters: 1.5).medianPairwiseDisagreementMeters == 0.002)
    #expect(model.estimate(for: .low, atDepthMeters: 1.5).medianPairwiseDisagreementMeters != nil)
}

// MARK: - The domain's edges

@Test func theDomainIsHalfOpenForEveryVerdict() throws {
    let model = try decoded(ModelFixture.artifact())
    for confidence in ConfidenceClass.allCases {
        #expect(model.estimate(for: confidence, atDepthMeters: 0.5).medianPairwiseDisagreementMeters != nil)
        #expect(model.estimate(for: confidence, atDepthMeters: 4.999).medianPairwiseDisagreementMeters != nil)
        #expect(model.estimate(for: confidence, atDepthMeters: 0.499) == .refusedOutsideDepthDomain)
        #expect(model.estimate(for: confidence, atDepthMeters: 5.0) == .refusedOutsideDepthDomain)
    }
}

@Test func aBandRunsFromItsLowerEdgeUpToTheNext() throws {
    let model = try decoded(ModelFixture.artifact())
    #expect(model.estimate(for: .high, atDepthMeters: 0.999)
        == .fromBandedTable(medianPairwiseDisagreementMeters: 0.001))
    #expect(model.estimate(for: .high, atDepthMeters: 1.0)
        == .fromBandedTable(medianPairwiseDisagreementMeters: 0.002))
}

// MARK: - The table

@Test func aTableWhoseMediansDoNotMatchItsBandsIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        high: ModelFixture.refused(table: #"{"edges": [0.5, 1.0, 5.0], "medians": [0.001]}"#)
    ))) == .malformedTable)
}

@Test func aTableWhoseEdgesDoNotAscendIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        high: ModelFixture.refused(table: #"{"edges": [0.5, 2.0, 1.0, 5.0], "medians": [0.001, 0.002, 0.003]}"#)
    ))) == .malformedTable)
}

/// A refused class has to answer wherever the domain does, except where a band
/// had no samples -- so a table that stops short of the domain is refused
/// rather than left to produce a third, unnamed kind of silence.
@Test func aTableThatDoesNotSpanTheDomainIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        high: ModelFixture.refused(table: #"{"edges": [0.5, 1.0, 3.0], "medians": [0.001, 0.002]}"#)
    ))) == .malformedTable)
}

// MARK: - The class set

@Test func aClassThisReaderCannotNameIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: ModelFixture.classes(
        extra: ", \"ultra\": \(ModelFixture.refused())"
    ))) == .unknownClass)
}

@Test func anArtifactMissingARegisteredClassIsRefused() throws {
    #expect(try rejection(ModelFixture.artifact(classes: """
        {"low": \(ModelFixture.adopted(form: "affine", coefficients: #"{"a": 0.02, "b": 0.01}"#)), \
        "high": \(ModelFixture.refused())}
        """)) == .missingField)
}
