#if canImport(ARKit) && os(iOS)
import ARKit
import CoreMotion
import Core
import QuartzCore
import Synchronization

/// Vends pose observations from a live `ARSession` by observing frame updates
/// through `ARSessionDelegate`, and inertial samples from Core Motion's fused
/// device motion.
///
/// Start the session through `run(_:options:)` rather than through the
/// `ARSession` directly: the same call establishes the timeline both sequences
/// are measured against, so the two cannot be performed out of order. Nothing
/// pairs a sample with an observation; sharing that one origin is the whole of
/// the alignment.
///
/// The two sequences arrive on two different threads -- `ARSessionDelegate`
/// callbacks on `session.delegateQueue`, device motion on a serial
/// `OperationQueue` owned here -- and at two different rates. Both reach the
/// same state through the same `Mutex`. This type does no I/O and holds neither
/// an `ARFrame` nor a `CMDeviceMotion` beyond its callback.
///
/// `@unchecked Sendable` because `ARSession`, `ARConfiguration`,
/// `CMMotionManager` and `OperationQueue` are not themselves `Sendable` in the
/// SDK. The mutable state is not part of that exemption -- it is held under the
/// `Mutex`.
public final class SensorSource: NSObject, PoseObservationSource, InertialSampleSource, ARSessionDelegate, @unchecked Sendable {
    private struct Stream {
        var continuation: AsyncThrowingStream<PoseObservation, any Error>.Continuation?
        var motionContinuation: AsyncThrowingStream<InertialSample, any Error>.Continuation?
        var origin: TimeInterval?
    }

    private let session: ARSession
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.skewline.capture.motion"
        // Serial. The handler reaches the same `Mutex` the frame callback does,
        // and a concurrent queue would let two samples interleave their yields.
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
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

    /// The device motion rate requested of Core Motion, in hertz.
    ///
    /// Deliberately above the rate the hardware fuses at. Requesting at a
    /// believed ceiling is the one request that cannot tell a ceiling from a
    /// grant; requesting above it makes the delivered rate a measurement
    /// either way. `deviceMotionUpdateInterval` is documented as capped to what
    /// the hardware supports, and the true rate is only knowable from the
    /// timestamps on delivered samples.
    ///
    /// Measured: this request delivers 99.45 Hz, a 10.055 ms interval. The
    /// ceiling is real, and asking for less would not have found it.
    public static let deviceMotionRate: Double = 200

    /// Establishes the timeline and starts both sensors against it.
    ///
    /// The origin is read once, here, rather than from the first frame -- which
    /// arrives some time after the session starts, and would therefore place
    /// any sensor sampled in that interval before zero.
    ///
    /// Ordering is load-bearing. The origin is stamped first, so no sample from
    /// either sensor can precede it. Device motion starts before `ARSession`,
    /// because Core Motion begins delivering long before ARKit's first frame
    /// and the interval between them is exactly what the shared origin exists
    /// to describe.
    public func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = []) {
        stream.withLock { $0.origin = CACurrentMediaTime() }

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / Self.deviceMotionRate
            // The default reference frame. Nothing recorded here depends on it:
            // it orients `attitude` and `heading`, and neither is kept.
            motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] deviceMotion, error in
                self?.receive(deviceMotion, error: error)
            }
        }

        session.run(configuration, options: options)
    }

    /// Ends both streams. Samples delivered afterwards are ignored.
    public func finish() {
        stopMotion()
        takeContinuation()?.finish()
        takeMotionContinuation()?.finish()
    }

    public func observations() -> AsyncThrowingStream<PoseObservation, any Error> {
        AsyncThrowingStream { continuation in
            stream.withLock { $0.continuation = continuation }
        }
    }

    public func inertialSamples() -> AsyncThrowingStream<InertialSample, any Error> {
        AsyncThrowingStream { continuation in
            stream.withLock { $0.motionContinuation = continuation }
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

    /// Called on `motionQueue` for every device motion update.
    private func receive(_ deviceMotion: CMDeviceMotion?, error: (any Error)?) {
        if let error {
            stopMotion()
            // The pose stream is untouched: one sensor failing is not the other
            // sensor failing.
            takeMotionContinuation()?.finish(throwing: error)
            return
        }
        guard let deviceMotion else { return }

        // Read out of the sample here and let it go, for the same reason the
        // frame callback does.
        let timestamp = deviceMotion.timestamp
        let rotationRate = deviceMotion.rotationRate
        let userAcceleration = deviceMotion.userAcceleration

        let (continuation, origin) = stream.withLock { ($0.motionContinuation, $0.origin) }
        guard let continuation, let origin else { return }

        continuation.yield(
            InertialSample(
                timestamp: timestamp - origin,
                rotationRate: SIMD3(rotationRate.x, rotationRate.y, rotationRate.z),
                userAcceleration: SIMD3(userAcceleration.x, userAcceleration.y, userAcceleration.z)
            )
        )
    }

    public func session(_ session: ARSession, didFailWithError error: any Error) {
        // The same teardown `finish()` performs. Without it a failed session
        // leaves the inertial stream open and the gyro running, because the
        // owner's stop path is guarded on a state the failure has already left.
        stopMotion()
        takeContinuation()?.finish(throwing: error)
        takeMotionContinuation()?.finish()
    }

    private func stopMotion() {
        if motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
        }
    }

    private func takeContinuation() -> AsyncThrowingStream<PoseObservation, any Error>.Continuation? {
        stream.withLock { stream in
            let continuation = stream.continuation
            stream.continuation = nil
            return continuation
        }
    }

    private func takeMotionContinuation() -> AsyncThrowingStream<InertialSample, any Error>.Continuation? {
        stream.withLock { stream in
            let continuation = stream.motionContinuation
            stream.motionContinuation = nil
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
