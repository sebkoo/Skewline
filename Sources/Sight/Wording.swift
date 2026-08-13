import Foundation
import Model

extension Sighting {
    /// The registered wording, and the reason this is a function rather than
    /// an interpolation at the call site.
    ///
    /// The artifact guards depth -- outside the fitted range every class
    /// refuses -- and guards scene not at all, because it cannot: the fit is
    /// leave-one-out over the sessions it names, so a number read off a scene
    /// that is not one of them is an extrapolation across scenes. A bare "this
    /// point disagrees by X" would hide that. The sentence carries where the
    /// number came from instead.
    ///
    /// It lives in `Sight` rather than in either caller because there are two
    /// callers: a probe printing to a terminal, and a client drawing to a
    /// phone. Copied into the second, the two would drift, and this repository
    /// has already made that argument twice -- about the artifact's readers,
    /// and about the page that would have been a third. Words drift the same
    /// way schemas do, and a refusal worded two ways is two findings to a
    /// reader who meets both.
    ///
    /// The session count is read from `model.trainedOn`, never written in:
    /// the provenance is the artifact's to state, and a literal here would be
    /// a number that stops being true when the fit is rerun.
    public func sentence(from model: FittedModel) -> String {
        let sessions = model.trainedOn.count
        switch self {
        case .model(.fromAdoptedForm(let meters)):
            return "on the \(sessions) sessions this was fitted from, two views of a point"
                + " like this disagreed by about \(Self.fixed(meters)) m"
        case .model(.fromBandedTable(let meters)):
            return "no form was adopted for this class; on the \(sessions) sessions this was"
                + " fitted from, its band disagreed by about \(Self.fixed(meters)) m"
        case .model(.refusedBandWithoutSamples):
            return "refused: inside the fitted depths, but this band had no samples"
        case .model(.refusedOutsideDepthDomain):
            return "refused: outside the depths this was fitted over, nothing answers"
        case .noDepthReturned:
            return "refused: the sensor returned no depth at this pixel"
        case .unknownConfidenceClass(let raw):
            return "refused: the sensor reported class \(raw), which no fold was fitted over"
        }
    }

    /// Six decimals for a disagreement, the scale the fit's own transcript
    /// prints at.
    private static func fixed(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
