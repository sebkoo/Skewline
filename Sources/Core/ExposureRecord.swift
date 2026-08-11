import Foundation

/// One camera frame's exposure settings, the operands blur is made of.
///
/// Blur is physics: exposure duration times angular velocity. The latter is
/// already carried by `InertialSample.rotationRate` on the same timeline;
/// this record holds the other factor.
public struct ExposureRecord: Codable, Equatable, Sendable {
    /// `ARCamera.exposureDuration`, in seconds -- the motion-blur factor.
    public var duration: TimeInterval

    /// `ARCamera.exposureOffset`, in EV (exposure value) units -- the
    /// cheapest per-frame scene-illumination scalar ARKit types. Recorded
    /// because the tracker's quality label does not encode motion (the
    /// anti-correlation finding: `excessiveMotion` at 1.28 rad/s, `normal`
    /// at 23.32 rad/s), so a model separating scene effects from motion
    /// effects needs a scene scalar of its own, not the label.
    public var offset: Float

    public init(duration: TimeInterval, offset: Float) {
        self.duration = duration
        self.offset = offset
    }
}
