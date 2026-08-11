#if canImport(ARKit) && os(iOS)
import ARKit
import CoreMotion
import CoreVideo
import Core
import QuartzCore
import simd
import Synchronization

/// Knobs for the camera-frame path -- configuration values chosen from device
/// measurements, not starting points.
///
/// v0.4 ran a device matrix against a written criterion -- drops at or below
/// 1% of callbacks, and no chronic interior drop pattern -- and set every
/// default below from what passed it. See DEVLOG, "the knobs get their
/// defaults."
public struct VideoCaptureConfiguration: Sendable {
    /// Keep every Nth delivered frame; 1 keeps them all. Applied at the
    /// source, before the pixel copy, so a strided-out frame costs nothing.
    /// Default is 2: stride 1 dropped chronically on this hardware, stride 2
    /// held the criterion with only an isolated, non-repeating stall.
    public var frameStride: Int

    /// Upper bound on copied frames waiting for the consumer. Bounds the
    /// path's memory at `bufferDepth` × one frame's bytes -- depth maps
    /// included, when the frame carries them; when the buffer is full the
    /// incoming frame is dropped and counted.
    public var bufferDepth: Int

    public init(frameStride: Int = 2, bufferDepth: Int = 8) {
        precondition(frameStride >= 1, "frameStride must be at least 1")
        precondition(bufferDepth >= 1, "bufferDepth must be at least 1")
        self.frameStride = frameStride
        self.bufferDepth = bufferDepth
    }
}

/// The depth captured beside one camera frame's pixels.
///
/// No timestamp: both maps come from the same `ARFrame` as the camera frame
/// that carries this value, so the frame's timestamp is theirs.
///
/// `@unchecked Sendable` in its own right, not by riding inside
/// `CameraFrame`'s exemption -- an `@unchecked` container merely silences the
/// check for its members. The terms are the same: both buffers are deep
/// copies owned by this value, yielded to exactly one consumer, and never
/// touched by the producer again.
public struct CapturedDepth: @unchecked Sendable {
    /// The depth map, in ARKit's own pixel format, as delivered.
    public let depthMap: CVPixelBuffer

    /// ARKit's per-pixel confidence in `depthMap`, or `nil` when the frame
    /// delivered none -- `ARDepthData.confidenceMap` is nullable.
    public let confidenceMap: CVPixelBuffer?

    public init(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?) {
        self.depthMap = depthMap
        self.confidenceMap = confidenceMap
    }
}

/// One camera frame leaving the live path: the frame's capture time on the
/// session timeline, its pixels, and the depth captured with them.
///
/// `@unchecked Sendable` on the same honesty terms as `SensorSource` itself:
/// `pixelBuffer` is a deep copy owned by this value, yielded to exactly one
/// consumer, and never touched by the producer again.
public struct CameraFrame: @unchecked Sendable {
    /// Capture time, seconds since the owning session's start -- the same
    /// timeline as `PoseObservation.timestamp` and `InertialSample.timestamp`,
    /// normalised against the same origin.
    public let timestamp: TimeInterval

    /// The frame's pixels, in the camera's own pixel format.
    public let pixelBuffer: CVPixelBuffer

    /// The frame's scene depth, or `nil` when the `ARFrame` carried none --
    /// the semantic was not enabled, the device has no depth sensor, or ARKit
    /// simply delivered nothing for this frame.
    public let depth: CapturedDepth?

    /// `ARCamera.exposureDuration`, in seconds. Not optional: every `ARFrame`
    /// carries a non-nil `camera`, so unlike depth there is no per-frame
    /// absence to model.
    public let exposureDuration: TimeInterval

    /// `ARCamera.exposureOffset`, in EV (exposure value) units.
    public let exposureOffset: Float

    /// `ARCamera.intrinsics`, the pinhole camera matrix at capture -- raw,
    /// like `pixelBuffer`. Decomposing it into the four measured entries and
    /// verifying the rest are the pinhole model's constants is
    /// `FrameEncoder`'s job, the same split `DepthEncoder` makes for pixel
    /// format.
    public let intrinsics: simd_float3x3

    /// `ARCamera.imageResolution`, the pixel resolution `intrinsics` is
    /// expressed at. Not the resolution of `pixelBuffer` or of a depth map
    /// from the same frame -- those become `FrameRecord.width`/`height`,
    /// describing the stored payload; this describes the frame the
    /// intrinsics were computed in.
    public let intrinsicsReferenceSize: CGSize

    public init(
        timestamp: TimeInterval,
        pixelBuffer: CVPixelBuffer,
        depth: CapturedDepth? = nil,
        exposureDuration: TimeInterval,
        exposureOffset: Float,
        intrinsics: simd_float3x3,
        intrinsicsReferenceSize: CGSize
    ) {
        self.timestamp = timestamp
        self.pixelBuffer = pixelBuffer
        self.depth = depth
        self.exposureDuration = exposureDuration
        self.exposureOffset = exposureOffset
        self.intrinsics = intrinsics
        self.intrinsicsReferenceSize = intrinsicsReferenceSize
    }
}

/// Failure modes of the live camera-frame path.
public enum CameraCaptureError: Error {
    /// Allocating or filling the deep copy of a `capturedImage` failed.
    case pixelBufferCopyFailed
}

/// Vends pose observations and camera frames from a live `ARSession` by
/// observing frame updates through `ARSessionDelegate`, and inertial samples
/// from Core Motion's fused device motion.
///
/// Start the session through `run(_:options:)` rather than through the
/// `ARSession` directly: the same call establishes the timeline all sequences
/// are measured against, so the two cannot be performed out of order. Nothing
/// pairs one sequence's element with another's; sharing that one origin is the
/// whole of the alignment.
///
/// The sequences arrive on two different threads -- `ARSessionDelegate`
/// callbacks on `session.delegateQueue` carry both the pose and the camera
/// frame, device motion arrives on a serial `OperationQueue` owned here -- and
/// at different rates. All reach the same state through the same `Mutex`. This
/// type does no I/O and holds neither an `ARFrame` nor a `CMDeviceMotion`
/// beyond its callback; a kept camera frame leaves as a copy this type
/// allocates, never as ARKit's own buffer.
///
/// `@unchecked Sendable` because `ARSession`, `ARConfiguration`,
/// `CMMotionManager` and `OperationQueue` are not themselves `Sendable` in the
/// SDK. The mutable state is not part of that exemption -- it is held under the
/// `Mutex`.
public final class SensorSource: NSObject, PoseObservationSource, InertialSampleSource, ARSessionDelegate, @unchecked Sendable {
    private struct Stream {
        var continuation: AsyncThrowingStream<PoseObservation, any Error>.Continuation?
        var motionContinuation: AsyncThrowingStream<InertialSample, any Error>.Continuation?
        var frameContinuation: AsyncThrowingStream<CameraFrame, any Error>.Continuation?
        var origin: TimeInterval?
        var frameIndex = 0
        var keptFrames = 0
        var droppedFrames = 0
        var stridedFrames = 0
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
    private let video: VideoCaptureConfiguration

    public init(session: ARSession, video: VideoCaptureConfiguration = VideoCaptureConfiguration()) {
        self.session = session
        self.video = video
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

    /// Ends all three streams. Samples delivered afterwards are ignored.
    public func finish() {
        stopMotion()
        takeContinuation()?.finish()
        takeMotionContinuation()?.finish()
        takeFrameContinuation()?.finish()
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

    /// The camera-frame sequence, bounded.
    ///
    /// Built with `.bufferingOldest`: at most
    /// `VideoCaptureConfiguration.bufferDepth` copied frames wait for the
    /// consumer, so the path's memory is bounded by construction, and when the
    /// consumer falls behind it is the incoming frame that is refused --
    /// counted in `droppedCameraFrames` -- rather than the buffer growing.
    ///
    /// Every delegate callback that arrives while this stream is live lands in
    /// exactly one of `keptCameraFrames`, `droppedCameraFrames` or
    /// `stridedCameraFrames` -- disjoint by construction, so
    /// `callbacks = kept + dropped + strided` closes and a probe's ceiling
    /// number can be trusted to distinguish policy from backpressure.
    public func cameraFrames() -> AsyncThrowingStream<CameraFrame, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(video.bufferDepth)) { continuation in
            stream.withLock { $0.frameContinuation = continuation }
        }
    }

    /// Camera frames yielded and accepted by the stream's buffer.
    public var keptCameraFrames: Int {
        stream.withLock { $0.keptFrames }
    }

    /// Camera frames refused by the stream's bounded buffer. Backpressure
    /// only: a frame skipped by `frameStride` is counted in
    /// `stridedCameraFrames` instead, never here.
    public var droppedCameraFrames: Int {
        stream.withLock { $0.droppedFrames }
    }

    /// Camera frames skipped by `VideoCaptureConfiguration.frameStride`.
    /// Policy, not backpressure -- skipped before the pixel copy, so they cost
    /// nothing -- and neither kept nor dropped.
    public var stridedCameraFrames: Int {
        stream.withLock { $0.stridedFrames }
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

        recordCameraFrame(from: frame)
    }

    /// The camera side of one `didUpdate` callback: apply the stride, copy the
    /// kept frame's pixels, yield the copy.
    private func recordCameraFrame(from frame: ARFrame) {
        enum Decision {
            case off
            case strided
            case keep(AsyncThrowingStream<CameraFrame, any Error>.Continuation, TimeInterval)
        }

        // Classified under the lock, so the stride index and the counters
        // cannot interleave with another callback's.
        let decision: Decision = stream.withLock { state in
            guard let continuation = state.frameContinuation, let origin = state.origin else {
                // No consumer, or no timeline yet: the frame was never a
                // candidate, and the counters' arithmetic does not include it.
                return .off
            }
            let index = state.frameIndex
            state.frameIndex += 1
            guard index.isMultiple(of: video.frameStride) else {
                state.stridedFrames += 1
                return .strided
            }
            return .keep(continuation, origin)
        }
        guard case .keep(let continuation, let origin) = decision else { return }

        // The copy happens before the yield, so a frame the stream refuses has
        // already paid it. Deliberate: copying only after acceptance would
        // mean retaining ARKit's own buffer across the yield, the thing the
        // pose path above exists to avoid.
        guard let copy = Self.copy(frame.capturedImage) else {
            // An allocation this size failing mid-capture is not a per-frame
            // condition to skip past; fail the stream loudly rather than let
            // the file look whole with frames silently missing.
            takeFrameContinuation()?.finish(throwing: CameraCaptureError.pixelBufferCopyFailed)
            return
        }

        // Depth rides only on a kept frame -- copied here, after the stride
        // decision, so a strided frame pays for no depth copy. Presence of
        // `sceneDepth` is the whole condition: whether the semantic is on is
        // the session configuration's business, not a second knob here.
        var depth: CapturedDepth?
        if let sceneDepth = frame.sceneDepth {
            guard let depthCopy = Self.copy(sceneDepth.depthMap) else {
                takeFrameContinuation()?.finish(throwing: CameraCaptureError.pixelBufferCopyFailed)
                return
            }
            var confidenceCopy: CVPixelBuffer?
            if let confidenceMap = sceneDepth.confidenceMap {
                guard let copied = Self.copy(confidenceMap) else {
                    takeFrameContinuation()?.finish(throwing: CameraCaptureError.pixelBufferCopyFailed)
                    return
                }
                confidenceCopy = copied
            }
            depth = CapturedDepth(depthMap: depthCopy, confidenceMap: confidenceCopy)
        }

        let result = continuation.yield(
            CameraFrame(
                timestamp: frame.timestamp - origin,
                pixelBuffer: copy,
                depth: depth,
                exposureDuration: frame.camera.exposureDuration,
                exposureOffset: frame.camera.exposureOffset,
                intrinsics: frame.camera.intrinsics,
                intrinsicsReferenceSize: frame.camera.imageResolution
            )
        )
        stream.withLock { state in
            switch result {
            case .enqueued:
                state.keptFrames += 1
            case .dropped:
                // Backpressure, and only backpressure: the buffer was full, so
                // the incoming frame -- copy already paid -- is discarded.
                state.droppedFrames += 1
            case .terminated:
                // `finish()` won the race against this callback. The frame is
                // outside the stream's lifetime, like one before `run()`, and
                // is counted nowhere.
                break
            @unknown default:
                break
            }
        }
    }

    /// A deep copy of `source` in its own pixel format, with its attachments.
    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            nil,
            &created
        )
        guard status == kCVReturnSuccess, let copy = created else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        // Plane by plane, row by row: the two buffers can disagree on row
        // padding, and a single memcpy of the whole allocation would shear the
        // image whenever they do.
        let planeCount = CVPixelBufferIsPlanar(source) ? CVPixelBufferGetPlaneCount(source) : 1
        for plane in 0..<planeCount {
            let src: UnsafeMutableRawPointer?
            let dst: UnsafeMutableRawPointer?
            let srcStride: Int
            let dstStride: Int
            let height: Int
            if CVPixelBufferIsPlanar(source) {
                src = CVPixelBufferGetBaseAddressOfPlane(source, plane)
                dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
                srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                dstStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                height = CVPixelBufferGetHeightOfPlane(source, plane)
            } else {
                src = CVPixelBufferGetBaseAddress(source)
                dst = CVPixelBufferGetBaseAddress(copy)
                srcStride = CVPixelBufferGetBytesPerRow(source)
                dstStride = CVPixelBufferGetBytesPerRow(copy)
                height = CVPixelBufferGetHeight(source)
            }
            guard let src, let dst else { return nil }
            if srcStride == dstStride {
                memcpy(dst, src, srcStride * height)
            } else {
                let rowBytes = min(srcStride, dstStride)
                for row in 0..<height {
                    memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), rowBytes)
                }
            }
        }

        // Color space and the rest of the metadata ride on the buffer, not in
        // the pixels; without them a consumer would be guessing.
        CVBufferPropagateAttachments(source, copy)
        return copy
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
        // The error itself travels on the pose stream; the other two end
        // cleanly.
        stopMotion()
        takeContinuation()?.finish(throwing: error)
        takeMotionContinuation()?.finish()
        takeFrameContinuation()?.finish()
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

    private func takeFrameContinuation() -> AsyncThrowingStream<CameraFrame, any Error>.Continuation? {
        stream.withLock { stream in
            let continuation = stream.frameContinuation
            stream.frameContinuation = nil
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
