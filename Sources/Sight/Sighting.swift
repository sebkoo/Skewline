import Model

/// What the model says about one sighted pixel, or which silence.
///
/// Three cases, and the first one nests rather than flattening: `Estimate`
/// already carries two answers and two silences, and those silences are the
/// *model's* -- outside the fitted depths nothing answers, and a band with no
/// samples has no median anyone measured. The two below are the *sensor's*,
/// and they happen before the model is consulted at all. Flattening the five
/// into one enum would say the two kinds are one kind, which is the collapse
/// `Estimate`'s own four cases exist to refuse.
public enum Sighting: Sendable, Equatable {
    /// The sensor gave a reading this artifact has a class for, and the model
    /// answered on its own terms -- including by refusing on them.
    case model(Estimate)

    /// The sensor returned no depth at that pixel: zero, negative, or not
    /// finite. The same guard the calibration run applies before it will use a
    /// sample at all.
    case noDepthReturned

    /// The sensor reported a confidence this artifact has no class for.
    ///
    /// `skewline-fit/1` names three classes and the sensor's own enum
    /// documents three raw values; anything above them is a reading no fold
    /// was ever fitted over. Named for the class rather than for a domain,
    /// because "domain" in this repository already means the depth domain and
    /// the two refusals are different findings.
    case unknownConfidenceClass(rawValue: UInt8)

    /// The estimate when there is one, `nil` for every silence.
    ///
    /// The name is the estimand, carried through from `Estimate`: the median
    /// **pairwise** disagreement of two same-class readings of the same point
    /// across frames, in meters. Not one reading's error bar, and not an
    /// interval on a distance between two points -- see the span refused in
    /// docs/ROADMAP.md.
    public var medianPairwiseDisagreementMeters: Double? {
        switch self {
        case .model(let estimate): estimate.medianPairwiseDisagreementMeters
        case .noDepthReturned, .unknownConfidenceClass: nil
        }
    }
}

extension FittedModel {
    /// What the model says about one depth sample and the class the sensor
    /// gave it.
    ///
    /// `depthMeters` is the depth map's own sample, unmodified: **planar z**,
    /// the pixel's distance along the optical axis. It is the quantity the
    /// model was fitted on -- `Calibration` regresses against the source
    /// frame's `depths[index]`, straight off the sensor -- and it is *not* the
    /// length of the viewing ray. A raycast hit distance exceeds it by
    /// `1 / cos` of the angle off axis, which is a silent fifteen per cent at
    /// thirty degrees and would apply the model to a depth it never saw.
    ///
    /// `rawConfidence` is the sensor's own raw value, 0/1/2, never remapped --
    /// the same integer `ConfidencePoint` carries and the calibration export's
    /// `class` column holds.
    ///
    /// Depth is checked before class: a pixel with no return has no reading,
    /// so whatever class the sensor stamped on it describes nothing.
    ///
    /// Evaluated locally, always. The service answers no per-point query,
    /// because "how wrong is a reading at this depth" would send the asker's
    /// own depths up the wire -- and this is the first client that genuinely
    /// has per-point questions.
    public func sighting(depthMeters: Float, rawConfidence: UInt8) -> Sighting {
        guard depthMeters > 0, depthMeters.isFinite else { return .noDepthReturned }
        // Written out rather than indexed into `allCases`. The order is the
        // same and the artifact's class names came from these integers, but
        // an array subscript would carry the mapping in a coincidence of
        // declaration order -- and this mapping is the one thing here that
        // could be wrong without anything going red.
        let confidence: ConfidenceClass
        switch rawConfidence {
        case 0: confidence = .low
        case 1: confidence = .medium
        case 2: confidence = .high
        default: return .unknownConfidenceClass(rawValue: rawConfidence)
        }
        return .model(estimate(for: confidence, atDepthMeters: Double(depthMeters)))
    }
}
