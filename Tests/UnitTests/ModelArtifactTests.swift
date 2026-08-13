import Testing
import Foundation
import Model

// The contract is reached through the one file the service serves. Copying
// `Fit/model.json` into `Tests/` would create a second copy to drift, so this
// walks up from its own source path instead -- and a missing file is a
// failure, never a skip: a check that silently skips when its anchor
// disappears is decoration.
//
// Nothing here transcribes a fitted number. Every assertion is either a
// registered constant or is re-derived from the decoded artifact itself, so a
// refit that changes the coefficients leaves these green and a decoder that
// starts inventing numbers does not.

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // Tests/UnitTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // the repository root

private let artifactURL = repositoryRoot.appending(path: "Fit/model.json")

private func committedModel() throws -> FittedModel {
    #expect(
        FileManager.default.fileExists(atPath: artifactURL.path()),
        "the committed artifact is missing at \(artifactURL.path())"
    )
    return try FittedModel(decoding: try Data(contentsOf: artifactURL))
}

@Test func theCommittedArtifactDecodes() throws {
    let model = try committedModel()
    #expect(model.depthDomain == 0.5..<5.0)
    #expect(!model.estimand.isEmpty)
    #expect(!model.trainedOn.isEmpty)
    // The provenance the artifact makes machine-visible has to agree with
    // itself: one export per session it was trained on, in the same order.
    #expect(model.trainedOn == model.export.map(\.session))
}

/// Leave-one-out gives one fold per container, so the fold count is the
/// container count -- not a number this test knows, a relation it checks.
@Test func everyClassCarriesOneFoldPerContainerItWasTrainedOn() throws {
    let model = try committedModel()
    for confidence in ConfidenceClass.allCases {
        let folds = model.classes[confidence].folds
        #expect(folds.count == model.trainedOn.count)
        for fold in folds {
            #expect(model.trainedOn.contains(fold.holdout))
        }
    }
}

/// The adoption bar, re-derived from the decoded numbers: a form is adopted
/// only if it beats the fold's own table in every fold, and a class is refused
/// only if no candidate did.
@Test func everyVerdictAgreesWithItsOwnFolds() throws {
    let model = try committedModel()
    for confidence in ConfidenceClass.allCases {
        let classModel = model.classes[confidence]
        func sweeps(_ name: String) -> Bool {
            classModel.folds.allSatisfy { fold in
                if case .scored(let metric, _)? = fold.forms[name] {
                    return metric < fold.tableMetric
                }
                return false
            }
        }
        switch classModel.verdict {
        case .adopted(let form):
            #expect(sweeps(form.name), "\(confidence.rawValue) adopted \(form.name), which lost a fold")
        case .refused:
            for name in Set(classModel.folds.flatMap(\.forms.keys)).sorted() {
                #expect(
                    !sweeps(name),
                    "\(confidence.rawValue) is refused although \(name) beat the table in every fold"
                )
            }
        }
    }
}

/// What the model answers has to be what the model says: a form's estimate is
/// that form evaluated, and a table's estimate is that band's own median.
@Test func everyClassAnswersFromWhatItActuallyCarries() throws {
    let model = try committedModel()
    let depth = 2.5
    for confidence in ConfidenceClass.allCases {
        switch model.classes[confidence].verdict {
        case .adopted(let form):
            let expected: Double = switch form {
            case .affine(let a, let b): a + b * depth
            case .quadratic(let a, let b): a + b * depth * depth
            case .power(let a, let p): a * pow(depth, p)
            }
            #expect(model.estimate(for: confidence, atDepthMeters: depth)
                == .fromAdoptedForm(medianPairwiseDisagreementMeters: expected))
        case .refused(let table):
            let band = try #require(table.band(containingDepthMeters: depth))
            let median = try #require(table.medians[band])
            #expect(model.estimate(for: confidence, atDepthMeters: depth)
                == .fromBandedTable(medianPairwiseDisagreementMeters: median))
        }
    }
}

/// A refused class is not an unavailable one: it answers at every depth the
/// domain covers, which is what keeping the banded table bought.
@Test func aRefusedClassInTheCommittedArtifactStillAnswersAcrossTheDomain() throws {
    let model = try committedModel()
    let refused = ConfidenceClass.allCases.filter {
        if case .refused = model.classes[$0].verdict { return true }
        return false
    }
    for confidence in refused {
        for depth in [0.5, 1.0, 2.0, 3.0, 4.9] {
            #expect(model.estimate(for: confidence, atDepthMeters: depth)
                .medianPairwiseDisagreementMeters != nil)
        }
    }
}

@Test func nothingAnswersOutsideTheDomain() throws {
    let model = try committedModel()
    for confidence in ConfidenceClass.allCases {
        #expect(model.estimate(for: confidence, atDepthMeters: 0.4) == .refusedOutsideDepthDomain)
        #expect(model.estimate(for: confidence, atDepthMeters: 5.0) == .refusedOutsideDepthDomain)
        #expect(model.estimate(for: confidence, atDepthMeters: 12.0) == .refusedOutsideDepthDomain)
    }
}
