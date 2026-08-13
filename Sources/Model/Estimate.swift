import Foundation

/// What the model says at one depth for one confidence class.
///
/// Four cases, because "refused" and "unavailable" are different things and a
/// type that conflates them throws away the finding v0.6 fought for. A class
/// whose verdict is `refused` still answers -- through its banded table, which
/// is exactly why that table was kept -- so the refusal of a *form* is not the
/// refusal of an *answer*. Only the last two cases are silences, and they are
/// different silences: outside the depth domain nothing answers at all, while
/// inside it a band with no samples has no median anyone measured.
public enum Estimate: Sendable, Equatable {
    /// The class's adopted continuous form answered.
    case fromAdoptedForm(medianPairwiseDisagreementMeters: Double)

    /// The class refused a continuous form and its banded table answered.
    case fromBandedTable(medianPairwiseDisagreementMeters: Double)

    /// Inside the depth domain, but the band holding this depth had no
    /// samples, so no median exists to hand back.
    case refusedBandWithoutSamples

    /// Outside the depth domain, where the artifact's own `outsideDomain:
    /// refuse` says nothing answers.
    case refusedOutsideDepthDomain

    /// The estimate when there is one, `nil` for either silence.
    ///
    /// The name is the estimand: the **median pairwise** disagreement of two
    /// same-class readings of the same point across frames, in meters. It is
    /// not a single-reading sigma, and a consumer that wants a per-reading
    /// error bar states its own conversion.
    public var medianPairwiseDisagreementMeters: Double? {
        switch self {
        case .fromAdoptedForm(let meters), .fromBandedTable(let meters): meters
        case .refusedBandWithoutSamples, .refusedOutsideDepthDomain: nil
        }
    }
}

extension FittedModel {
    /// The model's estimate for one class at one depth.
    ///
    /// Evaluated locally, always: the service hands the whole artifact down
    /// and answers no per-point query, because "how wrong is a reading at this
    /// depth" would send the asker's own depths up the wire.
    public func estimate(for confidence: ConfidenceClass, atDepthMeters depth: Double) -> Estimate {
        guard depthDomain.contains(depth) else { return .refusedOutsideDepthDomain }
        switch classes[confidence].verdict {
        case .adopted(let form):
            return .fromAdoptedForm(medianPairwiseDisagreementMeters: form.value(atDepthMeters: depth))
        case .refused(let table):
            guard let band = table.band(containingDepthMeters: depth),
                  let median = table.medians[band] else {
                return .refusedBandWithoutSamples
            }
            return .fromBandedTable(medianPairwiseDisagreementMeters: median)
        }
    }
}
