#if canImport(ARKit) && os(iOS)
import ARKit
import Core

/// Vends pose observations from a live `ARSession` by observing frame
/// updates through `ARSessionDelegate`. The caller owns configuring and
/// running the session (e.g. calling `run(_:)` with an `ARConfiguration`);
/// this type only bridges delegate callbacks onto the `PoseObservationSource`
/// boundary.
public final class SensorSource: NSObject, PoseObservationSource, ARSessionDelegate, @unchecked Sendable {
    private let session: ARSession
    private var continuation: AsyncThrowingStream<PoseObservation, any Error>.Continuation?

    public init(session: ARSession) {
        self.session = session
        super.init()
        session.delegate = self
    }

    public func observations() -> AsyncThrowingStream<PoseObservation, any Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // TODO(owner): covariance is not measured yet -- ARKit exposes no pose
        // uncertainty directly. Zero is a placeholder, not a claim of zero
        // error, until an uncertainty model is fitted to trackingQuality.
        let observation = PoseObservation(
            timestamp: frame.timestamp,
            transform: Transform4x4(frame.camera.transform),
            covariance: .zero,
            trackingQuality: TrackingQuality(frame.camera.trackingState)
        )
        continuation?.yield(observation)
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        continuation?.finish(throwing: error)
    }
}

extension TrackingQuality {
    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .notAvailable:
            self = .notAvailable
        case .normal:
            self = .normal
        case .limited(let reason):
            self = .limited(TrackingLimitedReason(reason))
        }
    }
}

extension TrackingLimitedReason {
    init(_ reason: ARCamera.TrackingState.Reason) {
        switch reason {
        case .initializing:
            self = .initializing
        case .relocalizing:
            self = .relocalizing
        case .excessiveMotion:
            self = .excessiveMotion
        case .insufficientFeatures:
            self = .insufficientFeatures
        @unknown default:
            // TODO(owner): decide the right fallback if ARKit adds a new reason.
            self = .initializing
        }
    }
}
#endif
