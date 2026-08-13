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
    public func sentence(from model: FittedModel, precision: Precision) -> String {
        let sessions = model.trainedOn.count
        switch self {
        case .model(.fromAdoptedForm(let meters)):
            return "on the \(sessions) sessions this was fitted from, two views of a point"
                + " like this disagreed by \(precision.quantity(meters))"
        case .model(.fromBandedTable(let meters)):
            return "no form was adopted for this class; on the \(sessions) sessions this was"
                + " fitted from, its band disagreed by \(precision.quantity(meters))"
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

    /// How the number is written, which is a property of the reader rather
    /// than of the measurement.
    ///
    /// One sentence and two scales, because the old wording was two things at
    /// once: "disagreed by about 0.004096 m" hedged with `about` and then
    /// printed six decimals nobody can act on. Both halves cannot be right --
    /// either the digits matter, in which case the hedge is noise, or a person
    /// is reading it, in which case the digits are.
    ///
    /// No default. A default is how a screen ends up printing the machine's
    /// scale because nobody chose, and choosing is the whole content of this
    /// type.
    public enum Precision: Sendable, Equatable {
        /// Six decimals of meters, unhedged. The scale `ModelProbe` and
        /// `fit.py` agree on digit for digit, and a hedge beside it would
        /// claim an imprecision the comparison depends on not having.
        case meters

        /// Whole millimeters, hedged. The scale a person holding the phone can
        /// act on: this repository's own measured range runs from about 3 mm
        /// to about 200 mm, so a millimeter is the last digit that means
        /// anything to them.
        case millimeters

        /// The quantity with its unit, and its hedge when it has one.
        func quantity(_ meters: Double) -> String {
            switch self {
            case .meters:
                return String(format: "%.6f m", meters)
            case .millimeters:
                // Rounded first, and the guard is on the rounded value rather
                // than on the raw one. Printing "0 mm" would read as "these
                // two views agreed", which is the one thing this number never
                // says -- and `%.0f` rounds half to even, so a guard on the
                // input lets exactly 0.5 mm through to print as "0 mm"
                // anyway. Guarding what is printed rather than what is passed
                // is the same correction `DepthMapGrid`'s clamp makes: the
                // rule has to be true of the result.
                let millimeters = (meters * 1000).rounded()
                // The bound drops the hedge, because "about under" is not a
                // quantity. Unreachable from the committed artifact and
                // reachable from a better one.
                return millimeters < 1
                    ? "under 1 mm"
                    : String(format: "about %.0f mm", millimeters)
            }
        }
    }
}
