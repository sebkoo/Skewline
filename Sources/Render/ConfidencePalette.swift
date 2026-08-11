import simd

/// The confidence->color mapping -- the thesis on screen. A cloud rendered in
/// one color would look uniformly authoritative, which is the failure mode
/// this package exists to name; the palette's whole job is to keep the three
/// sensor confidence levels visibly distinct.
///
/// The choices, stated as choices rather than measurements: low is loud red,
/// because the least-trusted points are the ones a viewer must not mistake
/// for geometry; medium is amber; high is a desaturated blue -- calm where
/// the data has earned calm, and separable from red under red-green
/// color-vision deficiency, which the reflexive red/amber/green ramp is not.
/// Every raw value above the three documented `ARConfidenceLevel` cases gets
/// magenta: a confidence ARKit never defined should look like an alarm, not
/// like a fourth level.
///
/// These constants live here, once, and reach the GPU as a buffer built from
/// `table` -- nothing in the `.metal` source repeats them, so the CPU
/// reference and the kernels cannot drift apart.
public enum ConfidencePalette {
    /// `ARConfidenceLevel.low` (raw 0).
    public static let low = SIMD4<UInt8>(214, 60, 48, 255)

    /// `ARConfidenceLevel.medium` (raw 1).
    public static let medium = SIMD4<UInt8>(232, 180, 40, 255)

    /// `ARConfidenceLevel.high` (raw 2).
    public static let high = SIMD4<UInt8>(96, 148, 216, 255)

    /// Any raw value the sensor's own enum does not document.
    public static let outOfDomain = SIMD4<UInt8>(255, 0, 255, 255)

    /// The GPU-facing form: index `min(confidence, 3)`, 16 bytes total.
    public static let table = [low, medium, high, outOfDomain]

    /// The CPU reference the kernels are tested against, total over all 256
    /// raw values.
    public static func color(for confidence: UInt8) -> SIMD4<UInt8> {
        table[Int(min(confidence, 3))]
    }
}
