import simd

/// One unprojected point: a world-space position and the depth sensor's own
/// confidence in the sample that produced it, carried as one value -- the
/// package's thesis at per-point scale. A position that travelled without its
/// confidence would look exactly as authoritative as one that earned it.
///
/// Deliberately not `Codable`: this is an in-memory value on the way to a
/// renderer, not a storage record -- the container already stores the depth
/// and confidence maps it was computed from, and a second on-disk form could
/// only drift from the first.
///
/// Note the cost of the pairing: `SIMD3<Float>` is 16-byte aligned, so the
/// stride is 32 bytes, not 17. Whether a render buffer keeps this layout or
/// packs its own is the kernel's decision, on measured numbers, not this
/// type's.
public struct ConfidencePoint: Equatable, Sendable {
    /// World-space position, in meters, in the session's coordinate frame --
    /// the one stamped at `run()` that every sequence in a capture shares.
    public var position: SIMD3<Float>

    /// The `ARConfidenceLevel` raw value recorded for the depth sample this
    /// point came from, as observed on the device, never remapped.
    public var confidence: UInt8

    public init(position: SIMD3<Float>, confidence: UInt8) {
        self.position = position
        self.confidence = confidence
    }
}
