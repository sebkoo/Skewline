import Foundation
import simd

/// A homogeneous 4x4 transform describing a 6-DoF pose (camera/device-in-world,
/// translation in `column3`).
///
/// `simd_float4x4` does not conform to `Codable`, so this type stores the same
/// sixteen `Float` values as four `SIMD4<Float>` columns instead -- which are
/// natively `Codable`/`Equatable`/`Sendable` -- and converts losslessly to and
/// from `simd_float4x4` for math/interop use.
public struct Transform4x4: Codable, Equatable, Sendable {
    public var column0: SIMD4<Float>
    public var column1: SIMD4<Float>
    public var column2: SIMD4<Float>
    public var column3: SIMD4<Float>

    public init(column0: SIMD4<Float>, column1: SIMD4<Float>, column2: SIMD4<Float>, column3: SIMD4<Float>) {
        self.column0 = column0
        self.column1 = column1
        self.column2 = column2
        self.column3 = column3
    }

    public init(_ matrix: simd_float4x4) {
        column0 = matrix.columns.0
        column1 = matrix.columns.1
        column2 = matrix.columns.2
        column3 = matrix.columns.3
    }

    public var simd: simd_float4x4 {
        simd_float4x4(columns: (column0, column1, column2, column3))
    }

    public static let identity = Transform4x4(matrix_identity_float4x4)
}

/// Covariance over the pose's [x, y, z, roll, pitch, yaw] degrees of freedom,
/// stored row-major as a flat 36-value array since Swift has no native
/// fixed-size matrix type that is also `Codable`. Units are meters^2 for the
/// translation block and radians^2 for the rotation block.
public struct PoseCovariance6x6: Codable, Equatable, Sendable {
    public var values: [Double]

    public init(values: [Double]) {
        precondition(values.count == 36, "PoseCovariance6x6 requires exactly 36 (6x6) values, got \(values.count)")
        self.values = values
    }

    public subscript(row: Int, column: Int) -> Double {
        get { values[row * 6 + column] }
        set { values[row * 6 + column] = newValue }
    }

    public static let zero = PoseCovariance6x6(values: [Double](repeating: 0, count: 36))
}

/// Why the tracker considers itself in `limited` quality.
public enum TrackingLimitedReason: String, Codable, Equatable, Sendable {
    case initializing
    case relocalizing
    case excessiveMotion
    case insufficientFeatures
}

/// The tracker's own confidence/quality signal at the instant of capture,
/// recorded per-observation so a future uncertainty model can be fitted
/// against it.
public enum TrackingQuality: Codable, Equatable, Sendable {
    case normal
    case limited(TrackingLimitedReason)
    case notAvailable
}

/// A single observation derived from one AR frame: a pose together with its
/// uncertainty and the tracker's confidence signal at that instant, all in
/// one value so the three never drift apart in storage or transit.
public struct PoseObservation: Codable, Equatable, Sendable {
    /// Frame capture time, seconds since the owning session's start.
    public var timestamp: TimeInterval

    /// Camera/device pose at this instant.
    public var transform: Transform4x4

    /// Covariance of `transform`, in the same frame as `transform`.
    public var covariance: PoseCovariance6x6

    /// The tracker's confidence/quality signal at this instant.
    public var trackingQuality: TrackingQuality

    public init(
        timestamp: TimeInterval,
        transform: Transform4x4,
        covariance: PoseCovariance6x6,
        trackingQuality: TrackingQuality
    ) {
        self.timestamp = timestamp
        self.transform = transform
        self.covariance = covariance
        self.trackingQuality = trackingQuality
    }
}
