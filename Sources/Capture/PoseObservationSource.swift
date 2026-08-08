import Core
import Replay

/// The ingest boundary: anything that can vend a stream of pose observations,
/// whether they were captured moments ago by a live sensor or recorded in a
/// prior session. A consumer written against this protocol works unchanged
/// against any conformer.
public protocol PoseObservationSource: Sendable {
    func observations() -> AsyncThrowingStream<PoseObservation, any Error>
}

/// Vends the observations already recorded in a `CaptureSession`. Reading the
/// session from disk is `Replay.SessionCodec`'s job; this type only adapts an
/// already-decoded session onto the streaming boundary.
public struct ReplaySessionSource: PoseObservationSource {
    public let session: CaptureSession

    public init(session: CaptureSession) {
        self.session = session
    }

    public func observations() -> AsyncThrowingStream<PoseObservation, any Error> {
        AsyncThrowingStream { continuation in
            for observation in session.observations {
                continuation.yield(observation)
            }
            continuation.finish()
        }
    }
}
