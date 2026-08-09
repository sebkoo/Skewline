#if canImport(ARKit) && os(iOS)
import ARKit
import Core
import QuartzCore
import Synchronization

/// Vends pose observations from a live `ARSession` by observing frame updates
/// through `ARSessionDelegate`.
///
/// Start the session through `run(_:options:)` rather than through the
/// `ARSession` directly: the same call establishes the timeline every
/// observation is measured against, so the two cannot be performed out of
/// order. `ARSessionDelegate` callbacks arrive on `session.delegateQueue`,
/// which is the main queue unless the owner sets otherwise, so this type does
/// no I/O and holds no reference to an `ARFrame` beyond the callback.
///
/// `@unchecked Sendable` because `ARSession` and `ARConfiguration` are not
/// themselves `Sendable` in the SDK. The mutable state is not part of that
/// exemption -- it is held under a `Mutex`.
public final class SensorSource: NSObject, PoseObservationSource, ARSessionDelegate, @unchecked Sendable {
    private struct Stream {
        var continuation: AsyncThrowingStream<PoseObservation, any Error>.Continuation?
        var origin: TimeInterval?
    }

    private let session: ARSession
    private let stream = Mutex(Stream())

    public init(session: ARSession) {
        self.session = session
        super.init()
        session.delegate = self
    }

    /// The monotonic reading taken when `run(_:options:)` started the session,
    /// or `nil` before then.
    ///
    /// A session file records observation timestamps relative to this value but
    /// not the value itself, so this property is the only way to recover the
    /// raw ARKit timestamp of an observation:
    /// `raw = observation.timestamp + timelineOrigin`.
    public var timelineOrigin: TimeInterval? {
        stream.withLock { $0.origin }
    }

    /// Establishes the observation timeline and starts the underlying session.
    ///
    /// The origin is read once, here, rather than from the first frame -- which
    /// arrives some time after the session starts, and would therefore place
    /// any sensor sampled in that interval before zero.
    public func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = []) {
        stream.withLock { $0.origin = CACurrentMediaTime() }
        session.run(configuration, options: options)
    }

    /// Ends the observation stream. Frames delivered afterwards are ignored.
    public func finish() {
        takeContinuation()?.finish()
    }

    public func observations() -> AsyncThrowingStream<PoseObservation, any Error> {
        AsyncThrowingStream { continuation in
            stream.withLock { $0.continuation = continuation }
        }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Read out of the frame here and let it go: retaining an ARFrame
        // starves the session's pool and stalls capture.
        let timestamp = frame.timestamp
        let transform = Transform4x4(frame.camera.transform)
        let trackingQuality = TrackingQuality(frame.camera.trackingState)

        let (continuation, origin) = stream.withLock { ($0.continuation, $0.origin) }
        // A frame that arrives before `run(_:options:)` -- or after `finish()`
        // -- has no timeline to be relative to, and is dropped rather than
        // given a timestamp that means something else.
        guard let continuation, let origin else { return }

        // TODO(owner): covariance is not measured yet -- ARKit exposes no pose
        // uncertainty directly. Zero is a placeholder, not a claim of zero
        // error, until an uncertainty model is fitted to trackingQuality.
        continuation.yield(
            PoseObservation(
                timestamp: timestamp - origin,
                transform: transform,
                covariance: .zero,
                trackingQuality: trackingQuality
            )
        )
    }

    public func session(_ session: ARSession, didFailWithError error: any Error) {
        takeContinuation()?.finish(throwing: error)
    }

    private func takeContinuation() -> AsyncThrowingStream<PoseObservation, any Error>.Continuation? {
        stream.withLock { stream in
            let continuation = stream.continuation
            stream.continuation = nil
            return continuation
        }
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
