import Foundation

/// One inertial measurement of how the device was moving, as distinct from
/// where it was.
///
/// This is deliberately not a `PoseObservation`. The two are different
/// measurements, from different hardware, arriving at different rates; merging
/// them would mean resampling one onto the other and discarding whatever did
/// not line up. A session carries the two sequences side by side and aligns
/// them only by sharing one timeline origin.
public struct InertialSample: Codable, Equatable, Sendable {
    /// Sample time, seconds since the owning session's start -- the same
    /// timeline as `PoseObservation.timestamp`, normalised against the same
    /// origin.
    public var timestamp: TimeInterval

    /// Angular velocity about the device's x, y and z axes, in radians per
    /// second, right-hand-rule signed.
    public var rotationRate: SIMD3<Double>

    /// Acceleration with gravity removed, in the device's own reference frame,
    /// in g. Total acceleration is this plus gravity, which is not recorded.
    public var userAcceleration: SIMD3<Double>

    public init(timestamp: TimeInterval, rotationRate: SIMD3<Double>, userAcceleration: SIMD3<Double>) {
        self.timestamp = timestamp
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
    }
}
